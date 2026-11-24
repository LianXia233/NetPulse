//! 下载引擎：多 CDN IP 池、动态分段、多连接、断点续传与分块可视化。
//!
//! 每个工作线程绑定一个由 DNS 解析得到的 CDN 节点 IP；失败时在 IP 池内轮换重试。

use crate::dns;
use crate::http::{parse_bind, parse_url, send, Req, ResolveCache};
use crate::{new_task, Task};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::IpAddr;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};

#[derive(Clone)]
pub struct CdnEntry {
    pub url: String,
    pub ip: String,
    pub dns: String,
    pub ms: u128,
}

pub struct WorkerStat {
    pub id: usize,
    pub ip: Mutex<String>,
    pub dns: Mutex<String>,
    pub cdn: Mutex<String>,
    pub bytes: AtomicU64,
    pub last_bytes: AtomicU64,
    pub speed_kbps: AtomicU64,
    pub chunks: AtomicU64,
    pub state: Mutex<String>,
    pub last_error: Mutex<String>,
}

impl WorkerStat {
    fn new(id: usize) -> Self {
        Self {
            id,
            ip: Mutex::new(String::new()),
            dns: Mutex::new(String::new()),
            cdn: Mutex::new(String::new()),
            bytes: AtomicU64::new(0),
            last_bytes: AtomicU64::new(0),
            speed_kbps: AtomicU64::new(0),
            chunks: AtomicU64::new(0),
            state: Mutex::new("待命".into()),
            last_error: Mutex::new(String::new()),
        }
    }
}

pub struct DlState {
    pub id: String,
    pub url: String,
    pub mirrors: Vec<String>,
    pub headers: Vec<(String, String)>,
    pub dns: Vec<String>,
    pub connections: usize,
    pub block_kb: u32,
    pub retries: u32,
    pub bind_ip: Option<IpAddr>,
    pub bind_if: String,
    pub ip_mode: String,
    pub dns_mode: String,
    pub name: String,
    pub dir: String,
    pub kind: Mutex<String>,
    pub parts_total: AtomicU64,
    pub parts_done: AtomicU64,
    pub size: AtomicU64,
    pub done: AtomicU64,
    pub speed_kbps: AtomicU64,
    pub status: Mutex<String>,
    pub error: Mutex<Option<String>>,
    pub data_path: Mutex<PathBuf>,
    pub meta_path: Mutex<PathBuf>,
    pub final_path: Mutex<PathBuf>,
    pub chunk_bounds: Mutex<Vec<(u64, u64)>>,
    pub chunk_done: Mutex<Option<Arc<Mutex<Vec<Arc<AtomicU64>>>>>>,
    /// 详情页专用聚合快照，最多 160 格；避免每次 detail 都遍历全部分块。
    pub cells: Mutex<Vec<(u64, u64, u64, u64)>>,
    pub resume: bool,
    pub chunk_size: AtomicU64,
    pub cdn: Mutex<Vec<CdnEntry>>,
    pub workers: Mutex<Vec<Arc<WorkerStat>>>,
}

static DLS: OnceLock<Mutex<HashMap<String, Arc<DlState>>>> = OnceLock::new();

fn dls() -> &'static Mutex<HashMap<String, Arc<DlState>>> {
    DLS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 批量解析资源接口时可能一次加入几十个任务；
/// 全局最多同时跑 3 个，其余排队，避免 20×8 条连接把手机拖死。
static DL_ACTIVE: AtomicUsize = AtomicUsize::new(0);
struct DlRunGuard;
impl Drop for DlRunGuard {
    fn drop(&mut self) {
        DL_ACTIVE.fetch_sub(1, Ordering::Relaxed);
    }
}

fn sanitize(name: &str) -> String {
    let mut out: String = name
        .chars()
        .map(|c| {
            if c.is_control() || "/\\:*?\"<>|".contains(c) {
                '_'
            } else {
                c
            }
        })
        .collect();
    if out.len() > 180 {
        out.truncate(180);
    }
    if out.trim().is_empty() {
        out = "download.bin".into();
    }
    out
}

fn name_from_url(u: &str) -> String {
    let path = u.split('?').next().unwrap_or(u);
    let last = path.rsplit('/').next().unwrap_or("");
    if last.is_empty() || last.contains("__down") {
        "netpulse_download.bin".into()
    } else {
        sanitize(last)
    }
}

/// 解析资源清单 JSON（例如游戏启动器的 resource?key=... 接口），
/// 递归提取所有 path/url/download 字段中的直连地址；不预制任何 URL。
pub fn resolve_resource_links(args: &Value) -> Result<Value, String> {
    let url = args["url"].as_str().ok_or("缺少资源地址")?;
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("资源地址必须是 HTTP(S)".into());
    }
    let mut req = Req::new("GET", url);
    req.read_timeout = Duration::from_secs(12);
    req.connect_timeout = Duration::from_secs(6);
    req.headers.push(("Accept".into(), "application/json".into()));
    let cache = ResolveCache::new(Vec::new(), Duration::from_secs(6));
    let mut resp = send(&req, &cache)?;
    if resp.status != 200 {
        return Err(format!("资源接口 HTTP {}", resp.status));
    }
    let mut body = String::new();
    resp.reader.take(16 * 1024 * 1024).read_to_string(&mut body).map_err(|e| e.to_string())?;
    let root: Value = serde_json::from_str(body.trim()).map_err(|e| format!("不是 JSON: {}", e))?;
    let mut out: Vec<Value> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    fn walk(v: &Value, out: &mut Vec<Value>, seen: &mut std::collections::HashSet<String>, name_hint: &str, size_hint: Option<u64>) {
        match v {
            Value::Object(map) => {
                let name = map.get("name").and_then(|x| x.as_str()).filter(|x| !x.is_empty()).unwrap_or(name_hint);
                let size = map.get("size").and_then(|x| {
                    x.as_u64().or_else(|| x.as_str().and_then(|s| s.parse::<u64>().ok()))
                }).or(size_hint);
                for (k, val) in map {
                    let lk = k.to_ascii_lowercase();
                    if let Some(u) = val.as_str() {
                        if u.starts_with("http://") || u.starts_with("https://") {
                            let is_download = lk == "path"
                                || lk == "url"
                                || lk == "download"
                                || lk == "download_url"
                                || lk == "downloadurl"
                                || lk == "download_path"
                                || lk == "downloadpath";
                            if is_download && seen.insert(u.to_string()) {
                                let mut n = name.to_string();
                                if n.is_empty() {
                                    n = u.split('?').next().unwrap_or(u).rsplit('/').next().unwrap_or("download.bin").to_string();
                                }
                                out.push(json!({
                                    "url": u,
                                    "name": sanitize(&n),
                                    "size": size,
                                    "key": k,
                                }));
                            }
                        }
                    } else {
                        walk(val, out, seen, name, size);
                    }
                }
            }
            Value::Array(a) => {
                for item in a { walk(item, out, seen, name_hint, size_hint); }
            }
            _ => {}
        }
    }
    walk(&root, &mut out, &mut seen, "", None);
    if out.is_empty() {
        return Err("JSON 中没有找到下载直连（path/url 字段）".into());
    }
    Ok(json!({"items": out, "count": out.len()}))
}

fn parse_content_range(v: &str) -> Option<u64> {
    // bytes 0-0/12345 或 bytes */12345
    let total = v.rsplit('/').next()?.trim();
    total.parse::<u64>().ok()
}

pub fn add(args: Value) -> Result<Value, String> {
    let url = args["url"]
        .as_str()
        .ok_or("缺少下载地址")?
        .trim()
        .to_string();
    let dir = args["dir"]
        .as_str()
        .ok_or("缺少保存目录")?
        .to_string();
    let mut name = args["name"]
        .as_str()
        .map(|s| sanitize(s))
        .unwrap_or_else(|| name_from_url(&url));
    // 流式清单本身不是可播放文件：默认落盘为 .ts / .mp4，并替换掉清单扩展名。
    if is_hls_url(&url) {
        let lower = name.to_lowercase();
        if lower.ends_with(".m3u8") {
            name = format!("{}.ts", &name[..name.len() - 5]);
        } else if !lower.ends_with(".ts") && !name.contains('.') {
            name.push_str(".ts");
        }
    } else if is_dash_url(&url) {
        let lower = name.to_lowercase();
        if lower.ends_with(".mpd") {
            name = format!("{}.mp4", &name[..name.len() - 4]);
        } else if !lower.ends_with(".mp4") && !name.contains('.') {
            name.push_str(".mp4");
        }
    }
    let connections = args["connections"].as_u64().unwrap_or(8).clamp(1, 32) as usize;
    let mut mirrors: Vec<String> = args["mirrors"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty() && s != &url)
                .collect()
        })
        .unwrap_or_default();
    mirrors.truncate(8);
    let headers: Vec<(String, String)> = args["headers"]
        .as_object()
        .map(|o| {
            o.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .filter(|(k, v)| !k.is_empty() && !v.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let retries = args["retries"].as_u64().unwrap_or(2).clamp(0, 10) as u32;
    let resume = args["resume"].as_bool().unwrap_or(false);
    let block_kb = args["block_kb"].as_u64().unwrap_or(0).clamp(0, 8192) as u32;
    let (bind_ip, bind_if) = parse_bind(args["bind"].as_str().unwrap_or(""));
    let ip_mode = args["ip_mode"].as_str().unwrap_or("auto").to_string();
    let dns_mode = args["dns_mode"].as_str().unwrap_or("all").to_string();
    let dns_servers: Vec<String> = args["dns_servers"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_else(|| vec!["223.5.5.5".into(), "119.29.29.29".into()]);
    let dir_path = PathBuf::from(&dir);
    fs::create_dir_all(&dir_path).map_err(|e| format!("无法创建目录: {}", e))?;

    let (task_id, task) = new_task("download");
    let id = task_id.clone();
    let state = Arc::new(DlState {
        id: id.clone(),
        url: url.clone(),
        mirrors: mirrors.clone(),
        headers: headers.clone(),
        dns: dns_servers.clone(),
        connections,
        block_kb,
        retries,
        bind_ip,
        bind_if: bind_if.clone(),
        ip_mode: ip_mode.clone(),
        dns_mode: dns_mode.clone(),
        name: name.clone(),
        dir: dir.clone(),
        kind: Mutex::new("http".into()),
        parts_total: AtomicU64::new(0),
        parts_done: AtomicU64::new(0),
        size: AtomicU64::new(0),
        done: AtomicU64::new(0),
        speed_kbps: AtomicU64::new(0),
        status: Mutex::new("probing".into()),
        error: Mutex::new(None),
        data_path: Mutex::new(dir_path.join(format!(".{}.pmdown", name))),
        meta_path: Mutex::new(dir_path.join(format!(".{}.pmdown.json", name))),
        final_path: Mutex::new(dir_path.join(&name)),
        chunk_bounds: Mutex::new(Vec::new()),
        chunk_done: Mutex::new(None),
        cells: Mutex::new(Vec::new()),
        resume,
        chunk_size: AtomicU64::new(0),
        cdn: Mutex::new(Vec::new()),
        workers: Mutex::new(Vec::new()),
    });
    dls().lock().unwrap().insert(id.clone(), state.clone());

    let st = state.clone();
    let tk = task.clone();
    thread::spawn(move || {
        run(st, tk, connections, dns_servers, mirrors, headers, retries, block_kb, bind_ip, bind_if, ip_mode, dns_mode)
    });
    Ok(json!({"task_id": task_id, "id": id, "name": name}))
}

fn build_req(method: &str, url: &str, headers: &[(String, String)]) -> Req {
    let mut r = Req::new(method, url);
    for (k, v) in headers {
        r.headers.push((k.clone(), v.clone()));
    }
    r
}

fn build_cdn_pool(urls: &[String], servers: &[String]) -> Vec<CdnEntry> {
    let mut out: Vec<CdnEntry> = Vec::new();
    for url in urls {
        let host = match parse_url(url) {
            Ok(p) => p.host,
            Err(_) => continue,
        };
        let mut got = false;
        // 设置里配置了几台 DNS 就全部查询，A / AAAA 都取；
        // 每条记录保留命中的 DNS 与耗时，Worker 才能显示真实来源。
        for qtype in [1u16, 28u16] {
            for a in dns::query_all(&host, servers, qtype, Duration::from_secs(3)) {
                if a.ips.is_empty() {
                    continue;
                }
                got = true;
                for ip in a.ips {
                    let ip = ip.to_string();
                    if !out.iter().any(|e| e.url == *url && e.ip == ip) {
                        out.push(CdnEntry { url: url.clone(), ip, dns: a.server.clone(), ms: a.elapsed_ms });
                    }
                }
            }
        }
        if !got {
            out.push(CdnEntry { url: url.clone(), ip: String::new(), dns: "自动".into(), ms: 0 });
        }
    }
    out
}

fn run(
    state: Arc<DlState>,
    task: Arc<Task>,
    connections: usize,
    dns_servers: Vec<String>,
    mirrors: Vec<String>,
    headers: Vec<(String, String)>,
    retries: u32,
    block_kb: u32,
    bind_ip: Option<IpAddr>,
    bind_if: String,
    ip_mode: String,
    dns_mode: String,
) {
    while DL_ACTIVE.fetch_add(1, Ordering::Relaxed) >= 3 {
        DL_ACTIVE.fetch_sub(1, Ordering::Relaxed);
        if task.cancel.load(Ordering::Relaxed) {
            task.finish("cancelled", json!({"reason": "排队时取消"}));
            return;
        }
        thread::sleep(Duration::from_millis(350));
    }
    let _run_guard = DlRunGuard;
    let cache = Arc::new(
        ResolveCache::new(dns_servers, Duration::from_secs(8)).with_modes(&dns_mode, &ip_mode),
    );
    let data_path = state.data_path.lock().unwrap().clone();
    let meta_path = state.meta_path.lock().unwrap().clone();
    let final_path = state.final_path.lock().unwrap().clone();
    // 流式清单：HLS / DASH 直接解析清单、下载分片并顺序拼接。
    let is_hls = is_hls_url(&state.url);
    let is_dash = is_dash_url(&state.url);
    if is_hls || is_dash {
        return run_manifest(
            state,
            task,
            cache,
            headers,
            bind_ip,
            bind_if,
            is_hls,
            data_path,
            meta_path,
            final_path,
        );
    }

    // 1) 探测大小与 Range 支持
    let mut size = 0u64;
    let mut supports_range = false;
    let mut head_err = String::new();
    let all_urls: Vec<String> = std::iter::once(state.url.clone()).chain(mirrors.iter().cloned()).collect();
    let mut probe_url = state.url.clone();
    for u in &all_urls {
        let mut head = build_req("HEAD", u, &headers);
        head.bind_ip = bind_ip;
        head.bind_if = bind_if.clone();
        match send(&head, &cache) {
        Ok(r) => {
            if r.status == 200 { probe_url = u.clone(); }
            if r.status == 200 {
                size = r
                    .header("content-length")
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(0);
                supports_range = r
                    .header("accept-ranges")
                    .map(|v| v.to_ascii_lowercase().contains("bytes"))
                    .unwrap_or(false);
                break;
            } else {
                head_err = format!("HEAD HTTP {}", r.status);
            }
        }
        Err(e) => head_err = e,
        }
    }
    if size == 0 || !supports_range {
        let mut req = build_req("GET", &probe_url, &headers);
        req.bind_ip = bind_ip;
        req.bind_if = bind_if.clone();
        req.headers.push(("Range".into(), "bytes=0-0".into()));
        match send(&req, &cache) {
            Ok(r) => {
                if r.status == 206 {
                    supports_range = true;
                    size = r
                        .header("content-range")
                        .and_then(parse_content_range)
                        .unwrap_or(0);
                } else if r.status == 200 {
                    size = r
                        .header("content-length")
                        .and_then(|v| v.parse::<u64>().ok())
                        .unwrap_or(0);
                }
            }
            Err(e) => {
                *state.error.lock().unwrap() = Some(format!("{} / {}", head_err, e));
                *state.status.lock().unwrap() = "error".into();
                task.emit(json!({"type": "error", "message": e}));
                task.finish("error", json!({"error": e}));
                return;
            }
        }
    }
    if size == 0 {
        let msg = "服务器未返回文件大小，无法分段下载".to_string();
        *state.error.lock().unwrap() = Some(msg.clone());
        *state.status.lock().unwrap() = "error".into();
        task.emit(json!({"type": "error", "message": msg}));
        task.finish("error", json!({"error": msg}));
        return;
    }
    state.size.store(size, Ordering::Relaxed);
    *state.status.lock().unwrap() = "running".into();
    task.emit(json!({
        "type": "probe", "size": size, "supports_range": supports_range,
        "name": state.name, "path": final_path.to_string_lossy()
    }));

    let pool = Arc::new(build_cdn_pool(&all_urls, &state.dns));
    *state.cdn.lock().unwrap() = (*pool).clone();
    task.emit(json!({
        "type": "cdn",
        "entries": pool.iter().map(|e| json!({"url": e.url, "ip": e.ip, "dns": e.dns, "ms": e.ms})).collect::<Vec<_>>()
    }));

    // 2) 分段（默认 6 倍连接数的动态队列）
    let target_chunks = (connections * 6).max(1) as u64;
    let auto_chunk = ((size + target_chunks - 1) / target_chunks).max(1 << 20);
    let chunk_size = if block_kb > 0 {
        (block_kb as u64 * 1024).max(64 * 1024).min(size.max(1))
    } else {
        auto_chunk
    };
    let mut chunks: Vec<(u64, u64, u64)> = Vec::new(); // start, end, done
    if supports_range {
        let mut pos = 0u64;
        while pos < size {
            let end = (pos + chunk_size - 1).min(size - 1);
            chunks.push((pos, end, 0));
            pos = end + 1;
        }
    } else {
        chunks.push((0, size - 1, 0));
    }
    let connections = if supports_range { connections } else { 1 };
    // 断点续传：resume 时直接沿用元数据里的分块边界，
    // 即使分片大小/线程数改过，也不会把旧进度套到新布局上。
    if let Ok(text) = fs::read_to_string(&meta_path) {
        if let Ok(meta) = serde_json::from_str::<Value>(&text) {
            if meta["url"].as_str() == Some(state.url.as_str())
                && meta["size"].as_u64() == Some(size)
            {
                if let Some(arr) = meta["chunks"].as_array() {
                    if state.resume {
                        let mut restored: Vec<(u64, u64, u64)> = arr
                            .iter()
                            .filter_map(|c| {
                                let s = c["start"].as_u64()?;
                                let e = c["end"].as_u64()?;
                                let d = c["done"].as_u64().unwrap_or(0);
                                if e < s || e >= size { return None; }
                                Some((s, e, d.min(e - s + 1)))
                            })
                            .collect();
                        restored.sort_by_key(|c| c.0);
                        let covers = !restored.is_empty()
                            && restored.first().map(|c| c.0) == Some(0)
                            && restored.last().map(|c| c.1) == Some(size - 1)
                            && restored.windows(2).all(|w| w[0].1 + 1 >= w[1].0);
                        if covers {
                            chunks = restored;
                        }
                    } else {
                        for (i, c) in arr.iter().enumerate() {
                            if i < chunks.len() {
                                let done = c["done"].as_u64().unwrap_or(0)
                                    .min(chunks[i].1 - chunks[i].0 + 1);
                                chunks[i].2 = done;
                            }
                        }
                    }
                }
            }
        }
    }
    let file = match OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&data_path)
    {
        Ok(f) => {
            if f.metadata().map(|m| m.len()).unwrap_or(0) != size {
                let _ = f.set_len(size);
            }
            Arc::new(f)
        }
        Err(e) => {
            let msg = format!("创建文件失败: {}", e);
            *state.error.lock().unwrap() = Some(msg.clone());
            *state.status.lock().unwrap() = "error".into();
            task.emit(json!({"type": "error", "message": msg}));
            task.finish("error", json!({"error": msg}));
            return;
        }
    };

    let initial_done: u64 = chunks.iter().map(|c| c.2).sum();
    state.done.store(initial_done, Ordering::Relaxed);
    let chunk_done: Arc<Mutex<Vec<Arc<AtomicU64>>>> = Arc::new(Mutex::new(
        chunks
            .iter()
            .map(|c| Arc::new(AtomicU64::new(c.2)))
            .collect::<Vec<_>>(),
    ));
    *state.chunk_bounds.lock().unwrap() = chunks.iter().map(|c| (c.0, c.1)).collect();
    *state.chunk_done.lock().unwrap() = Some(chunk_done.clone());
    state.chunk_size.store(chunk_size, Ordering::Relaxed);
    let queue = Arc::new(AtomicUsize::new(0));
    // 失败分块重试队列：优先把尚未认领的新段发完，队列耗尽后再回收失败段。
    let retry_queue: Arc<Mutex<VecDeque<usize>>> = Arc::new(Mutex::new(VecDeque::new()));
    let retry_attempts: Arc<Mutex<HashMap<usize, u32>>> = Arc::new(Mutex::new(HashMap::new()));
    let cancel = task.cancel.clone();
    let chunks_meta: Arc<Mutex<Vec<(u64, u64)>>> = Arc::new(Mutex::new(
        chunks.iter().map(|c| (c.0, c.1)).collect(),
    ));
    // 每个分段的上界可以在运行时下调，用于把慢段对半拆开交给空闲连接。
    let limits: Arc<Mutex<Vec<Arc<AtomicU64>>>> = Arc::new(Mutex::new(
        chunks
            .iter()
            .map(|c| Arc::new(AtomicU64::new(c.1)))
            .collect(),
    ));

    let headers = Arc::new(headers.clone());
    let bind_if = Arc::new(bind_if);
    let retries = retries;
    let wstats: Vec<Arc<WorkerStat>> = (0..connections).map(|w| Arc::new(WorkerStat::new(w))).collect();
    *state.workers.lock().unwrap() = wstats.clone();
    // 连接数按需爬升：先 2 条探路，服务器持续供流时再逐步加码。
    let ramp = Arc::new(AtomicUsize::new(connections.min(2).max(1)));
    let mut handles = Vec::new();
    for w in 0..connections {
        let state = state.clone();
        let cache = cache.clone();
        let file = file.clone();
        let queue = queue.clone();
        let retry_queue = retry_queue.clone();
        let retry_attempts = retry_attempts.clone();
        let chunk_done = chunk_done.clone();
        let chunks_meta = chunks_meta.clone();
        let limits = limits.clone();
        let cancel = cancel.clone();
        let task = task.clone();
        let headers = headers.clone();
        let pool = pool.clone();
        let stat = wstats[w].clone();
        let bind_if = bind_if.clone();
        let ramp = ramp.clone();
        handles.push(thread::spawn(move || loop {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            while w >= ramp.load(Ordering::Relaxed) && !cancel.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_millis(150));
            }
            // 先认领新段；新段发完后再回收失败段，避免坏段垄断所有连接。
            let fresh = {
                let meta = chunks_meta.lock().unwrap();
                let q = queue.load(Ordering::Relaxed);
                if q >= meta.len() {
                    None
                } else {
                    queue.fetch_add(1, Ordering::Relaxed);
                    Some(q)
                }
            };
            let idx = fresh.or_else(|| retry_queue.lock().unwrap().pop_front());
            let Some(idx) = idx else {
                if cancel.load(Ordering::Relaxed)
                    || state.done.load(Ordering::Relaxed) >= state.size.load(Ordering::Relaxed)
                {
                    break;
                }
                thread::sleep(Duration::from_millis(120));
                continue;
            };
            let (start, end, cd, limit) = {
                let meta = chunks_meta.lock().unwrap();
                let (s, e) = meta[idx];
                let cd = chunk_done
                    .lock()
                    .unwrap()
                    .get(idx)
                    .cloned()
                    .unwrap_or_else(|| Arc::new(AtomicU64::new(0)));
                let lm = limits
                    .lock()
                    .unwrap()
                    .get(idx)
                    .cloned()
                    .unwrap_or_else(|| Arc::new(AtomicU64::new(e)));
                (s, e, cd, lm)
            };
            let total = end - start + 1;
            if cd.load(Ordering::Relaxed) >= total {
                continue;
            }
            *stat.state.lock().unwrap() = "下载中".into();
            let mut extra = 0u32;
            let result = loop {
                let r = download_chunk(
                    &pool,
                    w,
                    &cache,
                    &headers,
                    retries,
                    start,
                    end,
                    &file,
                    &cd,
                    limit.as_ref(),
                    &state.done,
                    &cancel,
                    &task,
                    supports_range,
                    &stat,
                    bind_ip,
                    bind_if.as_str(),
                );
                match r {
                    Err(e) if extra < 3 && !cancel.load(Ordering::Relaxed) => {
                        extra += 1;
                        *stat.last_error.lock().unwrap() = e;
                        thread::sleep(Duration::from_millis(250));
                    }
                    other => break other,
                }
            };
            match result {
                Ok(_) => {
                    stat.chunks.fetch_add(1, Ordering::Relaxed);
                    *stat.state.lock().unwrap() = "待命".into();
                }
                Err(e) => {
                    *stat.state.lock().unwrap() = "失败".into();
                    *stat.last_error.lock().unwrap() = e.clone();
                    task.emit(json!({"type": "chunk_error", "index": idx, "message": e}));
                    let attempt = {
                        let mut a = retry_attempts.lock().unwrap();
                        let n = a.entry(idx).or_insert(0);
                        *n += 1;
                        *n
                    };
                    if attempt < 12 {
                        retry_queue.lock().unwrap().push_back(idx);
                        thread::sleep(Duration::from_millis(350));
                    }
                }
            }
        }));
    }

    // 3) 采样 + 元数据落盘
    let start = Instant::now();
    let mut last = Instant::now();
    let mut last_done = initial_done;
    let mut watch_done = initial_done;
    let mut last_progress = Instant::now();
    let mut finished = false;
    let mut prev_done: Vec<u64> = chunk_done
        .lock()
        .unwrap()
        .iter()
        .map(|c| c.load(Ordering::Relaxed))
        .collect();
    let mut stall_since: Vec<Instant> = vec![Instant::now(); prev_done.len()];
    let mut split_count = 0usize;
    loop {
        thread::sleep(Duration::from_millis(500));
        let elapsed_ms = start.elapsed().as_millis() as usize;
        let target = (2 + elapsed_ms / 700).min(connections);
        ramp.store(target, Ordering::Relaxed);
        let done = state.done.load(Ordering::Relaxed).min(size);
        if done > watch_done {
            watch_done = done;
            last_progress = Instant::now();
        }
        // 长时间零进展：不再让任务停在“0 Mbps”假死，转为可续传的失败状态。
        if done < size
            && last_progress.elapsed() > Duration::from_secs(45)
            && !cancel.load(Ordering::Relaxed)
        {
            let msg = "连续 45 秒无进展，已停止；已下载分块保留，可点击继续断点续传".to_string();
            *state.error.lock().unwrap() = Some(msg.clone());
            *state.status.lock().unwrap() = "error".into();
            state.speed_kbps.store(0, Ordering::Relaxed);
            task.emit(json!({"type": "error", "message": msg}));
            task.finish("error", json!({"error": msg, "done": done, "size": size}));
            return;
        }
        let dt = last.elapsed().as_secs_f64().max(0.001);
        let mbps = ((done.saturating_sub(last_done)) as f64 * 8.0 / 1_000_000.0) / dt;
        state
            .speed_kbps
            .store((mbps * 100.0) as u64, Ordering::Relaxed);
        // 每个 Worker 的瞬时速率：按同一 500ms 窗口的字节增量计算。
        for w in wstats.iter() {
            let b = w.bytes.load(Ordering::Relaxed);
            let prev = w.last_bytes.swap(b, Ordering::Relaxed);
            let wmbps = ((b.saturating_sub(prev)) as f64 * 8.0 / 1_000_000.0) / dt;
            w.speed_kbps.store((wmbps * 100.0) as u64, Ordering::Relaxed);
        }

        // 运行时慢段接管：某段持续 1.2s 没有前进且仍有足够剩余时，
        // 把它的上界下调到剩余中点，并把后半截作为新段追加给空闲连接。
        {
            let mut meta = chunks_meta.lock().unwrap();
            let mut done_vec = chunk_done.lock().unwrap();
            let mut limit_vec = limits.lock().unwrap();
            let scan_len = meta.len();
            let now = Instant::now();
            let claimed = queue.load(Ordering::Relaxed);
            for idx in 0..scan_len {
                let d = done_vec[idx].load(Ordering::Relaxed);
                if d > prev_done[idx] {
                    prev_done[idx] = d;
                    stall_since[idx] = now;
                }
                let (s, e) = meta[idx];
                let total = e - s + 1;
                let active = idx < claimed;
                let remaining = total.saturating_sub(d);
                if active
                    && d < total
                    && remaining > 512 * 1024
                    && now.duration_since(stall_since[idx]) > Duration::from_millis(1200)
                    && split_count < connections * 2
                {
                    let split_at = s + d + remaining / 2;
                    if split_at > s + d && split_at < e {
                        limit_vec[idx].store(split_at, Ordering::Relaxed);
                        meta[idx] = (s, split_at);
                        meta.push((split_at + 1, e));
                        done_vec.push(Arc::new(AtomicU64::new(0)));
                        limit_vec.push(Arc::new(AtomicU64::new(e)));
                        prev_done.push(0);
                        stall_since.push(now);
                        split_count += 1;
                        let _ = task.emit(json!({
                            "type": "split", "index": idx, "at": split_at,
                            "left": [s, split_at], "right": [split_at + 1, e],
                        }));
                    }
                }
            }
            // 空闲连接抢速：当已有分段全部被认领、但仍存在空闲 Worker 时，
            // 直接选剩余量最大的在传分段对半拆开，不等待它“卡住”。
            let idle = wstats.iter().filter(|w| {
                let st = w.state.lock().unwrap();
                *st != "下载中" && *st != "失败"
            }).count();
            if idle > 0 && claimed >= scan_len && done < size && split_count < connections * 2 {
                let mut best: Option<(usize, u64)> = None;
                for idx in 0..scan_len {
                    let d = done_vec[idx].load(Ordering::Relaxed);
                    let (s, e) = meta[idx];
                    let remain = (e - s + 1).saturating_sub(d);
                    if d < e - s + 1 && remain > 512 * 1024 {
                        if best.map(|(_, r)| remain > r).unwrap_or(true) {
                            best = Some((idx, remain));
                        }
                    }
                }
                if let Some((idx, remain)) = best {
                    let d = done_vec[idx].load(Ordering::Relaxed);
                    let (s, e) = meta[idx];
                    let split_at = s + d + remain / 2;
                    if split_at > s + d && split_at < e {
                        limit_vec[idx].store(split_at, Ordering::Relaxed);
                        meta[idx] = (s, split_at);
                        meta.push((split_at + 1, e));
                        done_vec.push(Arc::new(AtomicU64::new(0)));
                        limit_vec.push(Arc::new(AtomicU64::new(e)));
                        prev_done.push(0);
                        stall_since.push(now);
                        split_count += 1;
                        let _ = task.emit(json!({
                            "type": "split", "index": idx, "at": split_at,
                            "left": [s, split_at], "right": [split_at + 1, e],
                            "reason": "idle-rescue",
                        }));
                    }
                }
            }
            *state.chunk_bounds.lock().unwrap() = meta.clone();
        }

        let meta_snapshot = chunks_meta.lock().unwrap().clone();
        let done_snapshot = chunk_done.lock().unwrap().clone();
        let done_counts: Vec<u64> = done_snapshot
            .iter()
            .map(|c| c.load(Ordering::Relaxed))
            .collect();
        // 详情页快照在 supervisor 里算一次，detail 调用只读 160 个聚合值。
        // 避免详情页轮询时反复遍历几万个 Atomic 并和下载线程抢锁。
        *state.cells.lock().unwrap() =
            build_display_cells(&meta_snapshot, &done_counts, 160);
        task.emit(json!({
            "type": "progress", "done": done, "size": size,
            "mbps": (mbps * 100.0).round() / 100.0,
            "elapsed_ms": start.elapsed().as_millis(),
            "chunks": done_counts,
        }));
        last = Instant::now();
        last_done = done;
        let _ = save_meta(&meta_path, &state.url, size, &done_snapshot, &meta_snapshot);
        if done >= size {
            finished = true;
            break;
        }
        if cancel.load(Ordering::Relaxed) {
            break;
        }
    }
    cancel.store(true, Ordering::Relaxed);
    for h in handles {
        let _ = h.join();
    }
    let done = state.done.load(Ordering::Relaxed).min(size);
    if finished || done >= size {
        let _ = file.sync_all();
        drop(file);
        if fs::rename(&data_path, &final_path).is_ok() {
            let _ = fs::remove_file(&meta_path);
            *state.status.lock().unwrap() = "done".into();
            task.emit(json!({"type": "done", "path": final_path.to_string_lossy(), "size": size}));
            task.finish(
                "done",
                json!({"path": final_path.to_string_lossy(), "size": size, "name": state.name}),
            );
            return;
        }
        let msg = "文件重命名失败".to_string();
        *state.error.lock().unwrap() = Some(msg.clone());
        *state.status.lock().unwrap() = "error".into();
        task.finish("error", json!({"error": msg}));
        return;
    }
    // 暂停/取消
    let stopped = cancel.load(Ordering::Relaxed);
    *state.status.lock().unwrap() = if stopped { "paused" } else { "error" }.into();
    if !stopped {
        *state.error.lock().unwrap() = Some("下载未完成：连接中断".into());
    }
    task.finish(
        if stopped { "paused" } else { "error" },
        json!({"done": done, "size": size, "path": data_path.to_string_lossy()}),
    );
}


fn is_hls_url(url: &str) -> bool {
    parse_url(url)
        .map(|p| p.path.split('?').next().unwrap_or("").to_ascii_lowercase().ends_with(".m3u8"))
        .unwrap_or(false)
}

fn is_dash_url(url: &str) -> bool {
    parse_url(url)
        .map(|p| p.path.split('?').next().unwrap_or("").to_ascii_lowercase().ends_with(".mpd"))
        .unwrap_or(false)
}

#[derive(Clone)]
struct StreamPart {
    url: String,
    range: Option<(u64, u64)>,
    key: Option<(Vec<u8>, [u8; 16])>,
}

fn resolve_url(base: &str, rel: &str) -> String {
    let rel = rel.trim();
    if rel.starts_with("http://") || rel.starts_with("https://") {
        return rel.to_string();
    }
    if rel.starts_with("//") {
        return format!("{}:{}", base.split("://").next().unwrap_or("https"), rel);
    }
    let scheme = base.split("://").next().unwrap_or("https");
    let rest = base.splitn(2, "://").nth(1).unwrap_or("");
    let authority = rest.split('/').next().unwrap_or("");
    if rel.starts_with('/') {
        return format!("{}://{}{}", scheme, authority, rel);
    }
    let dir = base.rsplit_once('/').map(|(d, _)| d).unwrap_or(base);
    format!("{}/{}", dir.trim_end_matches('/'), rel.trim_start_matches('/'))
}

fn fetch_bytes(
    url: &str,
    cache: &ResolveCache,
    headers: &[(String, String)],
    bind_ip: Option<IpAddr>,
    bind_if: &str,
    range: Option<(u64, u64)>,
) -> Result<Vec<u8>, String> {
    let mut req = build_req("GET", url, headers);
    req.bind_ip = bind_ip;
    req.bind_if = bind_if.to_string();
    req.read_timeout = Duration::from_secs(30);
    req.connect_timeout = Duration::from_secs(8);
    req.headers.push(("Accept-Encoding".into(), "identity".into()));
    if let Some((s, e)) = range {
        req.headers.push(("Range".into(), format!("bytes={}-{}", s, e)));
    }
    let mut r = send(&req, cache)?;
    if r.status != 200 && r.status != 206 {
        return Err(format!("HTTP {} ({})", r.status, url));
    }
    let mut out = Vec::new();
    r.reader
        .take(512 * 1024 * 1024)
        .read_to_end(&mut out)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

fn fetch_text(
    url: &str,
    cache: &ResolveCache,
    headers: &[(String, String)],
    bind_ip: Option<IpAddr>,
    bind_if: &str,
) -> Result<String, String> {
    let b = fetch_bytes(url, cache, headers, bind_ip, bind_if, None)?;
    String::from_utf8(b).map_err(|_| "清单不是 UTF-8 文本".to_string())
}

fn hls_attrs(s: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    let mut cur = String::new();
    let mut quoted = false;
    let mut parts = Vec::new();
    for ch in s.chars() {
        match ch {
            '"' => {
                quoted = !quoted;
                cur.push(ch);
            }
            ',' if !quoted => {
                parts.push(cur.clone());
                cur.clear();
            }
            _ => cur.push(ch),
        }
    }
    if !cur.trim().is_empty() {
        parts.push(cur);
    }
    for p in parts {
        if let Some((k, v)) = p.split_once('=') {
            out.insert(k.trim().to_ascii_uppercase(), v.trim().trim_matches('"').to_string());
        }
    }
    out
}

fn hex16(s: &str) -> Option<[u8; 16]> {
    let t = s.trim().trim_start_matches("0x").trim_start_matches("0X");
    if t.len() != 32 || !t.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = [0u8; 16];
    for i in 0..16 {
        out[i] = u8::from_str_radix(&t[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

fn seq_iv(seq: u64) -> [u8; 16] {
    let mut iv = [0u8; 16];
    iv[8..].copy_from_slice(&seq.to_be_bytes());
    iv
}

fn hls_parts(
    playlist: &str,
    base: &str,
    cache: &ResolveCache,
    headers: &[(String, String)],
    bind_ip: Option<IpAddr>,
    bind_if: &str,
) -> Result<Vec<StreamPart>, String> {
    let text = fetch_text(playlist, cache, headers, bind_ip, bind_if)?;
    let mut lines = text.lines().map(|s| s.trim()).filter(|s| !s.is_empty()).peekable();
    // 主清单：选择带宽最高的子清单。
    if lines.any(|l| l.starts_with("#EXT-X-STREAM-INF")) {
        let mut best: Option<(u64, String)> = None;
        let ls: Vec<&str> = text.lines().map(|s| s.trim()).collect();
        let mut i = 0;
        while i < ls.len() {
            if ls[i].starts_with("#EXT-X-STREAM-INF") {
                let attrs = hls_attrs(ls[i].split_once(':').map(|(_, v)| v).unwrap_or(""));
                let bw = attrs.get("BANDWIDTH").and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
                if i + 1 < ls.len() && !ls[i + 1].starts_with('#') {
                    let u = resolve_url(playlist, ls[i + 1]);
                    if best.as_ref().map(|(b, _)| bw > *b).unwrap_or(true) {
                        best = Some((bw, u));
                    }
                }
            }
            i += 1;
        }
        let child = best.map(|(_, u)| u).ok_or("HLS 主清单没有子清单")?;
        return hls_parts(&child, &child, cache, headers, bind_ip, bind_if);
    }
    let mut seq = 0u64;
    let mut key_uri: Option<String> = None;
    let mut key_bytes: Option<Vec<u8>> = None;
    let mut key_iv: Option<[u8; 16]> = None;
    let mut map_part: Option<StreamPart> = None;
    let mut pending_range: Option<(u64, u64)> = None;
    let mut parts = Vec::new();
    for line in text.lines().map(|s| s.trim()) {
        if let Some(v) = line.strip_prefix("#EXT-X-MEDIA-SEQUENCE:") {
            seq = v.trim().parse::<u64>().unwrap_or(0);
        } else if let Some(v) = line.strip_prefix("#EXT-X-KEY:") {
            let attrs = hls_attrs(v);
            let method = attrs.get("METHOD").map(|s| s.as_str()).unwrap_or("NONE");
            if method == "NONE" {
                key_uri = None;
                key_bytes = None;
                key_iv = None;
            } else if method == "AES-128" {
                let uri = attrs.get("URI").cloned().ok_or("HLS AES-128 缺少 URI")?;
                let abs = resolve_url(playlist, &uri);
                key_iv = attrs.get("IV").and_then(|v| hex16(v));
                if key_bytes.is_none() || key_uri.as_deref() != Some(abs.as_str()) {
                    let k = fetch_bytes(&abs, cache, headers, bind_ip, bind_if, None)?;
                    if k.len() != 16 {
                        return Err(format!("HLS AES key 长度异常: {}", k.len()));
                    }
                    key_bytes = Some(k);
                    key_uri = Some(abs);
                }
            } else {
                return Err(format!("暂不支持 HLS 加密方式 {}", method));
            }
        } else if let Some(v) = line.strip_prefix("#EXT-X-MAP:") {
            let attrs = hls_attrs(v);
            if let Some(uri) = attrs.get("URI") {
                map_part = Some(StreamPart {
                    url: resolve_url(base, uri),
                    range: None,
                    key: key_bytes.clone().map(|k| (k, key_iv.unwrap_or(seq_iv(seq)))),
                });
            }
        } else if let Some(v) = line.strip_prefix("#EXT-X-BYTERANGE:") {
            let (n, o) = v.split_once('@').unwrap_or((v, "0"));
            if let (Ok(n), Ok(o)) = (n.trim().parse::<u64>(), o.trim().parse::<u64>()) {
                pending_range = Some((o, o + n.saturating_sub(1)));
            }
        } else if !line.starts_with('#') {
            let url = resolve_url(base, line);
            let key = key_bytes.clone().map(|k| (k, key_iv.unwrap_or(seq_iv(seq))));
            parts.push(StreamPart { url, range: pending_range.take(), key });
            seq = seq.wrapping_add(1);
        }
    }
    if let Some(m) = map_part {
        parts.insert(0, m);
    }
    if parts.is_empty() {
        return Err("HLS 清单没有分片".into());
    }
    Ok(parts)
}

fn xml_attrs(tag: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    if let Ok(re) = regex::Regex::new(r#"([A-Za-z_:][A-Za-z0-9_:.-]*)="([^"]*)""#) {
        for c in re.captures_iter(tag) {
            out.insert(c[1].to_ascii_lowercase(), c[2].to_string());
        }
    }
    out
}

fn iso_duration_secs(s: &str) -> Option<f64> {
    let mut total = 0.0;
    let mut num = String::new();
    for ch in s.trim_start_matches("PT").chars() {
        if ch.is_ascii_digit() || ch == '.' {
            num.push(ch);
        } else {
            let v: f64 = num.parse().ok()?;
            num.clear();
            total += match ch {
                'H' => v * 3600.0,
                'M' => v * 60.0,
                'S' => v,
                _ => 0.0,
            };
        }
    }
    if total > 0.0 { Some(total) } else { None }
}

fn dash_parts(
    mpd_url: &str,
    cache: &ResolveCache,
    headers: &[(String, String)],
    bind_ip: Option<IpAddr>,
    bind_if: &str,
) -> Result<Vec<StreamPart>, String> {
    let text = fetch_text(mpd_url, cache, headers, bind_ip, bind_if)?;
    // 选码率最高的 Representation；找不到时退回整个 MPD。
    let mut best: Option<(u64, String)> = None;
    if let Ok(re) = regex::Regex::new(r#"<Representation\b[^>]*>"#) {
        for m in re.find_iter(&text) {
            let attrs = xml_attrs(m.as_str());
            let bw = attrs.get("bandwidth").and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
            let start = m.end();
            let end = text[start..].find("</Representation>").map(|e| start + e).unwrap_or(text.len());
            let block = &text[m.start()..end];
            if best.as_ref().map(|(b, _)| bw > *b).unwrap_or(true) {
                best = Some((bw, block.to_string()));
            }
        }
    }
    let block = best.map(|(_, b)| b).unwrap_or_else(|| text.clone());
    let base_url = regex::Regex::new(r#"<BaseURL>(.*?)</BaseURL>"#)
        .ok()
        .and_then(|re| re.captures(&block).map(|c| c[1].trim().to_string()))
        .map(|u| resolve_url(mpd_url, &u))
        .unwrap_or_else(|| mpd_url.to_string());
    let mut parts = Vec::new();
    if let Ok(re) = regex::Regex::new(r#"<Initialization\b[^>]*>"#) {
        if let Some(c) = re.captures(&block) {
            let attrs = xml_attrs(c.get(0).map(|m| m.as_str()).unwrap_or(""));
            if let Some(u) = attrs.get("sourceurl") {
                parts.push(StreamPart { url: resolve_url(&base_url, u), range: None, key: None });
            }
        }
    }
    if let Ok(re) = regex::Regex::new(r#"<SegmentURL\b[^>]*>"#) {
        for c in re.captures_iter(&block) {
            let attrs = xml_attrs(c.get(0).map(|m| m.as_str()).unwrap_or(""));
            if let Some(u) = attrs.get("media") {
                parts.push(StreamPart { url: resolve_url(&base_url, u), range: None, key: None });
            }
        }
    }
    if parts.is_empty() {
        if let Ok(re) = regex::Regex::new(r#"<SegmentTemplate\b[^>]*>"#) {
            if let Some(c) = re.captures(&block) {
                let attrs = xml_attrs(c.get(0).map(|m| m.as_str()).unwrap_or(""));
                let media = attrs.get("media").cloned().unwrap_or_default();
                let init = attrs.get("initialization").cloned().unwrap_or_default();
                let start_number = attrs.get("startnumber").and_then(|v| v.parse::<u64>().ok()).unwrap_or(1);
                let timescale = attrs.get("timescale").and_then(|v| v.parse::<f64>().ok()).unwrap_or(1.0);
                let seg_dur = attrs.get("duration").and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0);
                let total_secs = regex::Regex::new(r#"mediaPresentationDuration="([^"]+)""#)
                    .ok()
                    .and_then(|re| re.captures(&text).map(|c| c[1].to_string()))
                    .and_then(|s| iso_duration_secs(&s))
                    .unwrap_or(0.0);
                let count = if seg_dur > 0.0 && total_secs > 0.0 {
                    ((total_secs * timescale / seg_dur).ceil() as u64).max(1).min(100000)
                } else { 1 };
                let rep_id = regex::Regex::new(r#"<Representation\b[^>]*id="([^"]+)""#)
                    .ok()
                    .and_then(|re| re.captures(&block).map(|c| c[1].to_string()))
                    .unwrap_or_default();
                let bandwidth = regex::Regex::new(r#"<Representation\b[^>]*bandwidth="([^"]+)""#)
                    .ok()
                    .and_then(|re| re.captures(&block).map(|c| c[1].to_string()))
                    .unwrap_or_default();
                if !init.is_empty() {
                    parts.push(StreamPart { url: resolve_url(&base_url, &init), range: None, key: None });
                }
                for n in start_number..(start_number + count) {
                    let mut u = media.clone();
                    u = u.replace("$RepresentationID$", &rep_id).replace("$Bandwidth$", &bandwidth);
                    if let Ok(re) = regex::Regex::new(r#"\$Number%0(\d+)d\$"#) {
                        if let Some(c) = re.captures(&u) {
                            let w: usize = c[1].parse().unwrap_or(0);
                            let formatted = format!("{:0width$}", n, width = w);
                            u = re.replace_all(&u, formatted.as_str()).to_string();
                        }
                    }
                    u = u.replace("$Number$", &n.to_string());
                    if u.contains('$') {
                        // 未知模板变量（如 $Time$）不做猜测，交给服务端/后续实现。
                        continue;
                    }
                    parts.push(StreamPart { url: resolve_url(&base_url, &u), range: None, key: None });
                }
            }
        }
    }
    if parts.is_empty() {
        parts.push(StreamPart { url: base_url, range: None, key: None });
    }
    Ok(parts)
}

fn decrypt_hls(mut data: Vec<u8>, key: &[u8], iv: &[u8; 16]) -> Result<Vec<u8>, String> {
    if key.len() != 16 {
        return Err("HLS key 长度不是 16 字节".into());
    }
    let cipher = cbc::Decryptor::<aes::Aes128>::new_from_slices(key, iv)
        .map_err(|e| e.to_string())?;
    let plain = cipher
        .decrypt_padded_mut::<Pkcs7>(&mut data)
        .map_err(|e| format!("HLS 解密失败: {:?}", e))?;
    Ok(plain.to_vec())
}

#[allow(clippy::too_many_arguments)]
fn run_manifest(
    state: Arc<DlState>,
    task: Arc<Task>,
    cache: Arc<ResolveCache>,
    headers: Vec<(String, String)>,
    bind_ip: Option<IpAddr>,
    bind_if: String,
    hls: bool,
    data_path: PathBuf,
    meta_path: PathBuf,
    final_path: PathBuf,
) -> () {
    *state.status.lock().unwrap() = "running".into();
    *state.kind.lock().unwrap() = if hls { "hls" } else { "dash" }.into();
    task.set_status("running");
    task.emit(json!({"type":"manifest","kind": if hls {"hls"} else {"dash"}, "url": state.url}));
    let parts = if hls {
        hls_parts(&state.url, &state.url, &cache, &headers, bind_ip, &bind_if)
    } else {
        dash_parts(&state.url, &cache, &headers, bind_ip, &bind_if)
    };
    let parts = match parts {
        Ok(p) => p,
        Err(e) => {
            *state.error.lock().unwrap() = Some(e.clone());
            *state.status.lock().unwrap() = "error".into();
            task.emit(json!({"type":"error","message":e}));
            task.finish("error", json!({"error":e}));
            return;
        }
    };
    let mut file = match OpenOptions::new().create(true).truncate(true).write(true).open(&data_path) {
        Ok(f) => f,
        Err(e) => {
            let msg = format!("创建文件失败: {}", e);
            *state.error.lock().unwrap() = Some(msg.clone());
            *state.status.lock().unwrap() = "error".into();
            task.finish("error", json!({"error":msg}));
            return;
        }
    };
    let total_parts = parts.len();
    state.parts_total.store(total_parts as u64, Ordering::Relaxed);
    let mut done_parts = 0usize;
    let mut total_bytes = 0u64;
    for (i, p) in parts.iter().enumerate() {
        if task.is_cancelled() {
            break;
        }
        let r = fetch_bytes(&p.url, &cache, &headers, bind_ip, &bind_if, p.range);
        match r {
            Ok(mut bytes) => {
                if let Some((key, iv)) = &p.key {
                    match decrypt_hls(bytes, key, iv) {
                        Ok(plain) => bytes = plain,
                        Err(e) => {
                            *state.error.lock().unwrap() = Some(e.clone());
                            *state.status.lock().unwrap() = "error".into();
                            task.emit(json!({"type":"error","message":e}));
                            task.finish("error", json!({"error":e}));
                            return;
                        }
                    }
                }
                if let Err(e) = file.write_all(&bytes) {
                    let msg = format!("写入文件失败: {}", e);
                    *state.error.lock().unwrap() = Some(msg.clone());
                    *state.status.lock().unwrap() = "error".into();
                    task.finish("error", json!({"error":msg}));
                    return;
                }
                total_bytes += bytes.len() as u64;
                state.done.store(total_bytes, Ordering::Relaxed);
                done_parts += 1;
                state.parts_done.store(done_parts as u64, Ordering::Relaxed);
                task.emit(json!({
                    "type":"part", "index": i, "done_parts": done_parts, "total_parts": total_parts,
                    "bytes": total_bytes, "url": p.url
                }));
            }
            Err(e) => {
                *state.error.lock().unwrap() = Some(e.clone());
                *state.status.lock().unwrap() = "error".into();
                task.emit(json!({"type":"error","message":e}));
                task.finish("error", json!({"error":e}));
                return;
            }
        }
    }
    let cancelled = task.is_cancelled();
    if cancelled {
        *state.status.lock().unwrap() = "paused".into();
        task.finish("paused", json!({"done": total_bytes, "parts": done_parts}));
        return;
    }
    let _ = file.sync_all();
    drop(file);
    if fs::rename(&data_path, &final_path).is_ok() {
        let _ = fs::remove_file(&meta_path);
        state.size.store(total_bytes, Ordering::Relaxed);
        state.done.store(total_bytes, Ordering::Relaxed);
        *state.status.lock().unwrap() = "done".into();
        task.emit(json!({"type":"done","path":final_path.to_string_lossy(),"size":total_bytes,"parts":total_parts}));
        task.finish("done", json!({
            "path": final_path.to_string_lossy(), "size": total_bytes,
            "name": state.name, "parts": total_parts, "kind": if hls {"hls"} else {"dash"}
        }));
    } else {
        let msg = "文件重命名失败".to_string();
        *state.error.lock().unwrap() = Some(msg.clone());
        *state.status.lock().unwrap() = "error".into();
        task.finish("error", json!({"error":msg}));
    }
}

fn build_display_cells(
    bounds: &[(u64, u64)],
    done: &[u64],
    max_cells: usize,
) -> Vec<(u64, u64, u64, u64)> {
    if bounds.is_empty() {
        return Vec::new();
    }
    let cells = max_cells.max(1).min(bounds.len());
    let mut out = Vec::with_capacity(cells);
    for cell in 0..cells {
        let from = cell * bounds.len() / cells;
        let to = ((cell + 1) * bounds.len() / cells).max(from + 1).min(bounds.len());
        if from >= bounds.len() {
            break;
        }
        let s = bounds[from].0;
        let e = bounds[to - 1].1;
        let d: u64 = (from..to)
            .map(|i| done.get(i).copied().unwrap_or(0))
            .sum::<u64>()
            .min(e.saturating_sub(s) + 1);
        out.push((s, e, d, (to - from) as u64));
    }
    out
}

fn save_meta(
    path: &Path,
    url: &str,
    size: u64,
    chunk_done: &[Arc<AtomicU64>],
    chunks: &[(u64, u64)],
) -> Result<(), String> {
    let arr: Vec<Value> = chunks
        .iter()
        .enumerate()
        .map(|(i, (s, e))| {
            json!({
                "start": s, "end": e,
                "done": chunk_done[i].load(Ordering::Relaxed).min(e - s + 1)
            })
        })
        .collect();
    let text = json!({"url": url, "size": size, "chunks": arr}).to_string();
    fs::write(path, text).map_err(|e| e.to_string())
}

#[allow(clippy::too_many_arguments)]
fn download_chunk(
    pool: &[CdnEntry],
    worker_idx: usize,
    cache: &ResolveCache,
    headers: &[(String, String)],
    retries: u32,
    start: u64,
    end: u64,
    file: &Arc<File>,
    chunk_done: &AtomicU64,
    limit: &AtomicU64,
    total_done: &AtomicU64,
    cancel: &Arc<AtomicBool>,
    task: &Arc<Task>,
    supports_range: bool,
    worker: &Arc<WorkerStat>,
    bind_ip: Option<IpAddr>,
    bind_if: &str,
) -> Result<(), String> {
    let mut last_err = String::new();
    let mut offset = if supports_range {
        chunk_done.load(Ordering::Relaxed)
    } else {
        0
    };
    let effective_end = end.min(limit.load(Ordering::Relaxed));
    let expected_total = effective_end.saturating_sub(start) + 1;
    if offset >= expected_total {
        return Ok(());
    }
    let mut resp = None;
    for attempt in 0..=retries {
        let entry = &pool[(worker_idx + attempt as usize) % pool.len().max(1)];
        let mut req = build_req("GET", &entry.url, headers);
        req.bind_ip = bind_ip;
        req.bind_if = bind_if.to_string();
        req.pin_ip = entry.ip.parse().ok();
        req.pin_dns = Some(entry.dns.clone());
        if supports_range {
            req.headers.push((
                "Range".into(),
                format!("bytes={}-{}", start + offset, effective_end),
            ));
        }
        req.headers
            .push(("Accept-Encoding".into(), "identity".into()));
        *worker.ip.lock().unwrap() = entry.ip.clone();
        *worker.dns.lock().unwrap() = entry.dns.clone();
        *worker.cdn.lock().unwrap() = entry.url.clone();
        match send(&req, cache) {
            Ok(r) => {
                if supports_range && r.status == 206 {
                    if let Some(cr) = r.header("content-range") {
                        let expected = start + offset;
                        let got = cr
                            .split_whitespace()
                            .nth(1)
                            .and_then(|v| v.split('-').next())
                            .and_then(|v| v.parse::<u64>().ok());
                        if got != Some(expected) {
                            last_err = format!("Range 起点不符: {} ({})", cr, entry.url);
                            continue;
                        }
                    }
                }
                if (!supports_range && r.status == 200) || (supports_range && r.status == 206) {
                    resp = Some(r);
                    break;
                }
                last_err = format!("HTTP {} ({})", r.status, entry.url);
            }
            Err(e) => last_err = format!("{} ({})", e, entry.url),
        }
    }
    let mut resp = resp.ok_or_else(|| last_err)?;
    if supports_range && resp.status != 206 {
        return Err(format!("服务器未按 Range 返回: HTTP {}", resp.status));
    }
    if !supports_range && resp.status != 200 {
        return Err(format!("HTTP {}", resp.status));
    }
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Ok(());
        }
        let cap = end.min(limit.load(Ordering::Relaxed));
        let remain = cap.saturating_sub(start + offset) + 1;
        if remain == 0 || start + offset > cap {
            break;
        }
        let read_len = remain.min(buf.len() as u64) as usize;
        let n = match resp.reader.read(&mut buf[..read_len]) {
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                return Err(e.to_string());
            }
            Err(e) => return Err(e.to_string()),
        };
        if n == 0 {
            break;
        }
        let write_at = start + offset;
        file.write_at(&buf[..n], write_at).map_err(|e| e.to_string())?;
        offset += n as u64;
        chunk_done.store(offset, Ordering::Relaxed);
        total_done.fetch_add(n as u64, Ordering::Relaxed);
        worker.bytes.fetch_add(n as u64, Ordering::Relaxed);
    }
    let final_end = end.min(limit.load(Ordering::Relaxed));
    let expected = final_end.saturating_sub(start) + 1;
    if offset < expected {
        return Err(format!("分段未完成 {}/{}", offset, expected));
    }
    let _ = task;
    Ok(())
}

pub fn list() -> Value {
    let map = dls().lock().unwrap();
    let mut items = Vec::new();
    for (id, s) in map.iter() {
        items.push(json!({
            "id": id,
            "url": s.url,
            "name": s.name,
            "dir": s.dir,
            "size": s.size.load(Ordering::Relaxed),
            "done": s.done.load(Ordering::Relaxed),
            "mbps": (s.speed_kbps.load(Ordering::Relaxed) as f64) / 100.0,
                        "status": *s.status.lock().unwrap(),
            "error": *s.error.lock().unwrap(),
            "mirrors": s.mirrors,
            "kind": *s.kind.lock().unwrap(),
            "parts_total": s.parts_total.load(Ordering::Relaxed),
            "parts_done": s.parts_done.load(Ordering::Relaxed),
            "headers": s.headers.iter().cloned().collect::<HashMap<String, String>>(),
            "dns": s.dns,
            "connections": s.connections,
            "block_kb": s.block_kb,
            "retries": s.retries,
        }));
    }
    json!({"items": items})
}

pub fn detail(args: &Value) -> Result<Value, String> {
    let id = args["id"].as_str().ok_or("缺少 id")?;
    let state = dls().lock().unwrap().get(id).cloned().ok_or("任务不存在")?;
    let chunk_total = state.chunk_bounds.lock().unwrap().len();
    // 只读 supervisor 预聚合的 160 格，不再触碰每个分块的 Atomic 和锁。
    let cells = state.cells.lock().unwrap().clone();
    let chunks: Vec<Value> = cells
        .iter()
        .enumerate()
        .map(|(i, (s, e, d, count))| {
            let sz = e.saturating_sub(*s) + 1;
            json!({
                "index": i, "start": s, "end": e, "size": sz, "done": d,
                "count": count,
                "percent": if sz > 0 { (*d as f64 / sz as f64) * 100.0 } else { 0.0 }
            })
        })
        .collect();
    let workers: Vec<Value> = state.workers.lock().unwrap().iter().map(|w| json!({
        "id": w.id,
        "ip": *w.ip.lock().unwrap(),
        "dns": *w.dns.lock().unwrap(),
        "cdn": *w.cdn.lock().unwrap(),
        "bytes": w.bytes.load(Ordering::Relaxed),
        "mbps": (w.speed_kbps.load(Ordering::Relaxed) as f64) / 100.0,
        "chunks": w.chunks.load(Ordering::Relaxed),
        "state": *w.state.lock().unwrap(),
        "last_error": *w.last_error.lock().unwrap(),
    })).collect();
    let cdn: Vec<Value> = state.cdn.lock().unwrap().iter().map(|e| json!({
        "url": e.url, "ip": e.ip, "dns": e.dns, "ms": e.ms
    })).collect();
    Ok(json!({
        "id": id,
        "url": state.url,
        "mirrors": state.mirrors,
        "dns_servers": state.dns,
        "name": state.name,
        "size": state.size.load(Ordering::Relaxed),
        "done": state.done.load(Ordering::Relaxed),
        "mbps": (state.speed_kbps.load(Ordering::Relaxed) as f64) / 100.0,
        "status": *state.status.lock().unwrap(),
        "error": *state.error.lock().unwrap(),
        "chunk_size": state.chunk_size.load(Ordering::Relaxed),
        "chunk_total": chunk_total,
        "kind": *state.kind.lock().unwrap(),
        "parts_total": state.parts_total.load(Ordering::Relaxed),
        "parts_done": state.parts_done.load(Ordering::Relaxed),
        "chunks": chunks,
        "workers": workers,
        "cdn": cdn,
        "connections": state.connections,
    }))
}

/// 扫描下载目录里的 `.name.pmdown.json`，恢复被系统杀进程后丢失的任务记录。
/// 返回的条目只用于列表展示与断点继续；实际继续时以 meta 里的分块边界为准。
pub fn scan(args: &Value) -> Value {
    let dir = args["dir"].as_str().unwrap_or("").trim();
    if dir.is_empty() {
        return json!({"items": []});
    }
    let mut items: Vec<Value> = Vec::new();
    if let Ok(rd) = fs::read_dir(dir) {
        for entry in rd.flatten() {
            let path = entry.path();
            let fname = entry.file_name().to_string_lossy().to_string();
            if !fname.starts_with('.') || !fname.ends_with(".pmdown.json") {
                continue;
            }
            let name = fname
                .trim_start_matches('.')
                .trim_end_matches(".pmdown.json")
                .to_string();
            if name.is_empty() {
                continue;
            }
            let data_path = Path::new(dir).join(format!(".{}.pmdown", name));
            if !data_path.is_file() {
                continue;
            }
            let text = match fs::read_to_string(&path) {
                Ok(t) => t,
                Err(_) => continue,
            };
            let meta: Value = match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let url = meta["url"].as_str().unwrap_or("").to_string();
            if url.is_empty() {
                continue;
            }
            let size = meta["size"].as_u64().unwrap_or(0);
            let mut done = 0u64;
            let mut chunk_total = 0u64;
            if let Some(arr) = meta["chunks"].as_array() {
                chunk_total = arr.len() as u64;
                for c in arr {
                    done = done.saturating_add(c["done"].as_u64().unwrap_or(0));
                }
            }
            if size == 0 {
                continue;
            }
            let created = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            items.push(json!({
                "id": format!("local:{}", path.to_string_lossy()),
                "url": url,
                "name": name,
                "dir": dir,
                "size": size,
                "done": done.min(size),
                "mbps": 0,
                "status": "paused",
                "error": "",
                "mirrors": [],
                "headers": {},
                "dns": [],
                "connections": 8,
                "block_kb": 1024,
                "retries": 2,
                "kind": "http",
                "chunk_total": chunk_total,
                "parts_total": 0,
                "parts_done": 0,
                "recovered": true,
                "created": created,
            }));
        }
    }
    items.sort_by_key(|v| std::cmp::Reverse(v["created"].as_u64().unwrap_or(0)));
    json!({"items": items})
}

pub fn delete(args: &Value) -> Result<Value, String> {
    let id = args["id"].as_str().ok_or("缺少 id")?;
    let remove_files = args["delete_files"].as_bool().unwrap_or(true);
    let state = dls()
        .lock()
        .unwrap()
        .remove(id)
        .ok_or_else(|| "任务不存在".to_string())?;
    let task = crate::get_task(id).ok();
    if let Some(t) = task {
        t.cancel.store(true, Ordering::Relaxed);
    }
    if remove_files {
        let _ = fs::remove_file(state.data_path.lock().unwrap().clone());
        let _ = fs::remove_file(state.meta_path.lock().unwrap().clone());
    }
    Ok(json!({"id": id, "removed": true}))
}
