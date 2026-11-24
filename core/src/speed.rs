//! 多 CDN / 多 DNS 并发吞吐测试引擎。
//!
//! 关键点：
//! - 每个 worker 独立线程、独立连接，按 endpoints 轮询分配（多 CDN）；
//! - DNS 由 ResolveCache 在配置的多个服务器间轮询（多 DNS），并记录命中服务器与解析耗时；
//! - Range 随机起点绕过 CDN 缓存，读到的每个字节都计入全局原子计数；
//! - 采样线程按 sample_ms 输出瞬时 Mbps，结束后给出稳态均值/峰值。

use crate::http::{parse_bind, parse_url, send, Req, ResolveCache};
use crate::{new_task, Task};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Read;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Deserialize, Clone)]
#[serde(default)]
pub struct SpeedParams {
    pub mode: String,
    pub endpoints: Vec<String>,
    pub dns_servers: Vec<String>,
    pub workers: usize,
    pub buffer_kb: usize,
    pub duration_ms: u64,
    pub total_limit_bytes: u64,
    pub sample_ms: u64,
    pub timeout_ms: u64,
    pub bind: String,
    pub ip_mode: String,
    pub dns_mode: String,
}

impl Default for SpeedParams {
    fn default() -> Self {
        Self {
            mode: "download".into(),
            endpoints: vec!["https://speed.cloudflare.com/__down?bytes=25000000".into()],
            dns_servers: vec!["223.5.5.5".into(), "119.29.29.29".into()],
            workers: 8,
            buffer_kb: 64,
            duration_ms: 15000,
            total_limit_bytes: 0,
            sample_ms: 1000,
            timeout_ms: 8000,
            bind: String::new(),
            ip_mode: "auto".into(),
            dns_mode: "all".into(),
        }
    }
}

fn rnd(seed: &mut u64) -> u64 {
    let mut x = *seed;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *seed = x;
    x
}

pub fn start(args: Value) -> Result<Value, String> {
    let p: SpeedParams =
        serde_json::from_value(args).map_err(|e| format!("参数无效: {}", e))?;
    if p.endpoints.is_empty() {
        return Err("至少需要一个测速地址".into());
    }
    if p.mode != "download" && p.mode != "upload" {
        return Err("mode 只能是 download / upload".into());
    }
    let (id, task) = new_task("speed");
    let t = task.clone();
    thread::spawn(move || run(p, t));
    Ok(json!({"task_id": id}))
}

#[derive(Clone)]
struct SpeedRoute {
    endpoint: String,
    ip: String,
    dns: String,
}

/// 每个测速端点用「设置里的全部 DNS」并发解析，A/AAAA 都取；
/// 一个 CDN 域名解析出多个 IP 时，每个 Worker 能绑定不同 IP。
fn build_routes(endpoints: &[String], servers: &[String], timeout: Duration, ip_mode: &str, dns_mode: &str) -> Vec<SpeedRoute> {
    let mut handles = Vec::new();
    for endpoint in endpoints {
        let host = match parse_url(endpoint) {
            Ok(p) => p.host,
            Err(_) => continue,
        };
        let qtypes: Vec<u16> = match ip_mode {
            "v4" => vec![1],
            "v6" => vec![28],
            _ => vec![1, 28],
        };
        for qtype in qtypes {
            let endpoint = endpoint.clone();
            let mut servers = servers.to_vec();
            if dns_mode == "primary" && servers.len() > 1 {
                servers.truncate(1);
            }
            let host = host.clone();
            let ip_mode = ip_mode.to_string();
            handles.push(thread::spawn(move || {
                let answers = crate::dns::query_all(&host, &servers, qtype, timeout);
                (endpoint, answers, ip_mode)
            }));
        }
    }
    let mut routes: Vec<SpeedRoute> = Vec::new();
    for h in handles {
        if let Ok((endpoint, answers, ip_mode)) = h.join() {
            for a in answers {
                for ip in a.ips {
                    if (ip_mode == "v4" && !ip.is_ipv4()) || (ip_mode == "v6" && !ip.is_ipv6()) {
                        continue;
                    }
                    let ip = ip.to_string();
                    if !routes.iter().any(|r| r.endpoint == endpoint && r.ip == ip) {
                        routes.push(SpeedRoute {
                            endpoint: endpoint.clone(),
                            ip,
                            dns: a.server.clone(),
                        });
                    }
                }
            }
        }
    }
    if routes.is_empty() {
        for endpoint in endpoints {
            routes.push(SpeedRoute {
                endpoint: endpoint.clone(),
                ip: String::new(),
                dns: "自动".into(),
            });
        }
    }
    routes
}

fn run(p: SpeedParams, task: Arc<Task>) {
    let cancel = task.cancel.clone();
    let cache = Arc::new(
        ResolveCache::new(
            p.dns_servers.clone(),
            Duration::from_millis(p.timeout_ms.clamp(1000, 30000)),
        )
        .with_modes(&p.dns_mode, &p.ip_mode),
    );
    let routes = Arc::new(build_routes(
        &p.endpoints,
        &p.dns_servers,
        Duration::from_secs(3),
        &p.ip_mode,
        &p.dns_mode,
    ));
    let (bind_ip, bind_if) = parse_bind(&p.bind);
    let bind_if = Arc::new(bind_if);
    let bytes = Arc::new(AtomicU64::new(0));
    let errors = Arc::new(AtomicU64::new(0));
    let active = Arc::new(AtomicU64::new(0));
    let workers = p.workers.clamp(1, 128);
    let deadline = Instant::now() + Duration::from_millis(p.duration_ms.clamp(1000, 600000));
    let limit = p.total_limit_bytes;

    let mut handles = Vec::new();
    for i in 0..workers {
        let routes = routes.clone();
        let cache = cache.clone();
        let bytes = bytes.clone();
        let errors = errors.clone();
        let active = active.clone();
        let task = task.clone();
        let cancel = cancel.clone();
        let mode = p.mode.clone();
        let buffer = p.buffer_kb.clamp(4, 4096) * 1024;
        let bind_ip = bind_ip;
        let bind_if = bind_if.clone();
        handles.push(thread::spawn(move || {
            worker(
                i, routes, mode, buffer, cache, bytes, errors, active, task, cancel, deadline,
                limit, bind_ip, bind_if,
            )
        }));
    }

    let start = Instant::now();
    let mut last = Instant::now();
    let mut last_bytes = 0u64;
    let mut samples: Vec<(u64, f64)> = Vec::new();
    let mut peak: f64 = 0.0;
    let mut smooth: f64 = 0.0;
    let mut has_smooth = false;
    let mut anchor: Option<(Instant, u64)> = None;
    let warm_ms = (p.duration_ms as f64 * 0.15).max(800.0).min(4000.0) as u64;

    task.set_status("running");
    loop {
        thread::sleep(Duration::from_millis(p.sample_ms.clamp(100, 2000)));
        let now = Instant::now();
        let total = bytes.load(Ordering::Relaxed);
        let dt = now.duration_since(last).as_secs_f64().max(0.001);
        let raw = ((total - last_bytes) as f64 * 8.0 / 1_000_000.0) / dt;
        let t = start.elapsed().as_millis() as u64;
        // 指数平滑：抑制单次采样抖动，同时保持对真实变化的响应。
        if !has_smooth {
            smooth = raw;
            has_smooth = true;
        } else {
            let alpha = (p.sample_ms as f64 / 1000.0 / 2.0).clamp(0.12, 0.4);
            smooth = smooth * (1.0 - alpha) + raw * alpha;
        }
        if t >= warm_ms && smooth > peak {
            peak = smooth;
        }
        if anchor.is_none() && t >= warm_ms {
            anchor = Some((now, total));
        }
        samples.push((t, raw));
        task.emit(json!({
            "type": "sample",
            "t": t,
            "mbps": (raw * 100.0).round() / 100.0,
            "mbps_smooth": (smooth * 100.0).round() / 100.0,
            "bytes": total,
            "workers": active.load(Ordering::Relaxed),
            "errors": errors.load(Ordering::Relaxed),
        }));
        last = now;
        last_bytes = total;

        let over_time = now >= deadline;
        let over_limit = limit > 0 && total >= limit;
        if over_time || over_limit || cancel.load(Ordering::Relaxed) {
            break;
        }
    }
    let end_time = Instant::now();
    let total_end = bytes.load(Ordering::Relaxed);
    let cancelled = cancel.load(Ordering::Relaxed);
    cancel.store(true, Ordering::Relaxed);
    for h in handles {
        let _ = h.join();
    }

    let total = total_end;
    let elapsed = end_time.duration_since(start).as_secs_f64().max(0.001);
    let (base_time, base_bytes) = anchor.unwrap_or((start, 0));
    let steady_secs = end_time.duration_since(base_time).as_secs_f64().max(0.3);
    let steady = ((total.saturating_sub(base_bytes)) as f64 * 8.0 / 1_000_000.0) / steady_secs;
    let avg_all = (total as f64 * 8.0 / 1_000_000.0) / elapsed;
    let summary = json!({
        "mode": p.mode,
        "avg_mbps": (steady * 100.0).round() / 100.0,
        "steady_mbps": (steady * 100.0).round() / 100.0,
        "avg_all_mbps": (avg_all * 100.0).round() / 100.0,
        "peak_mbps": (peak.max(steady) * 100.0).round() / 100.0,
        "total_bytes": total,
        "duration_ms": end_time.duration_since(start).as_millis(),
        "errors": errors.load(Ordering::Relaxed),
        "workers": workers,
        "endpoints": p.endpoints,
    });
    task.emit(json!({"type": "done", "summary": summary}));
    task.finish(if cancelled { "cancelled" } else { "done" }, summary);
}

fn transient_speed_error(e: &str) -> bool {
    let e = e.to_ascii_lowercase();
    e.contains("unexpected end of file")
        || e.contains("try again")
        || e.contains("would block")
        || e.contains("timed out")
        || e.contains("connection reset")
        || e.contains("broken pipe")
        || e.contains("network is unreachable")
        || e.contains("os error 101")
        || e.contains("发送请求失败")
}

#[allow(clippy::too_many_arguments)]
fn worker(
    idx: usize,
    routes: Arc<Vec<SpeedRoute>>,
    mode: String,
    buffer: usize,
    cache: Arc<ResolveCache>,
    bytes: Arc<AtomicU64>,
    errors: Arc<AtomicU64>,
    active: Arc<AtomicU64>,
    task: Arc<Task>,
    cancel: Arc<AtomicBool>,
    deadline: Instant,
    limit: u64,
    bind_ip: Option<IpAddr>,
    bind_if: Arc<String>,
) {
    let first = routes.first().map(|r| r.endpoint.clone()).unwrap_or_default();
    task.emit(json!({"type": "worker", "idx": idx, "endpoint": first, "state": "start"}));
    let mut seed = (Instant::now().elapsed().as_nanos() as u64) ^ ((idx as u64) << 32) ^ 0x9E3779B97F4A7C15;
    let mut reported_route = false;
    let body = if mode == "upload" {
        let len = 4 * 1024 * 1024;
        let mut v = vec![0u8; len];
        let mut s = seed;
        for chunk in v.chunks_mut(4) {
            let r = rnd(&mut s) as u32;
            chunk.copy_from_slice(&r.to_le_bytes()[..chunk.len()]);
        }
        Some(Arc::new(v))
    } else {
        None
    };
    let mut attempt = 0usize;
    while !cancel.load(Ordering::Relaxed)
        && Instant::now() < deadline
        && (limit == 0 || bytes.load(Ordering::Relaxed) < limit)
    {
        let route = routes[(idx + attempt) % routes.len()].clone();
        let endpoint = route.endpoint.clone();
        attempt = attempt.wrapping_add(1);
        active.fetch_add(1, Ordering::Relaxed);
        let result = if mode == "upload" {
            upload_once(&route, body.as_ref().unwrap(), &cache, &bytes, bind_ip, bind_if.as_str())
        } else {
            download_once(
                idx,
                &route,
                buffer,
                &cache,
                &bytes,
                &cancel,
                &mut seed,
                &task,
                &mut reported_route,
                bind_ip,
                bind_if.as_str(),
            )
        };
        active.fetch_sub(1, Ordering::Relaxed);
        if let Err(e) = result {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            // 单个 CDN 提前断开/读超时/IPv6 无路由是测速常态，不把每次重试都抛到界面；
            // 真正协议/配置错误才计数并显示。
            if !transient_speed_error(&e) {
                errors.fetch_add(1, Ordering::Relaxed);
                task.emit(json!({"type": "error", "idx": idx, "endpoint": endpoint, "message": e}));
            }
            let backoff = (200 + errors.load(Ordering::Relaxed).min(5) * 150).min(900);
            thread::sleep(Duration::from_millis(backoff));
        }
    }
    task.emit(json!({"type": "worker", "idx": idx, "endpoint": first, "state": "stop"}));
}

#[allow(clippy::too_many_arguments)]
fn download_once(
    idx: usize,
    route: &SpeedRoute,
    buffer: usize,
    cache: &ResolveCache,
    bytes: &Arc<AtomicU64>,
    cancel: &Arc<AtomicBool>,
    seed: &mut u64,
    task: &Arc<Task>,
    reported_route: &mut bool,
    bind_ip: Option<IpAddr>,
    bind_if: &str,
) -> Result<(), String> {
    let offset = rnd(seed) % 1_000_000_000;
    let mut req = Req::new("GET", &route.endpoint);
    if let Ok(ip) = route.ip.parse() {
        req.pin_ip = Some(ip);
    }
    if !route.dns.is_empty() {
        req.pin_dns = Some(route.dns.clone());
    }
    req.bind_ip = bind_ip;
    req.bind_if = bind_if.to_string();
    req.read_timeout = Duration::from_millis(2500);
    req.connect_timeout = Duration::from_millis(4000);
    req.headers
        .push(("Range".into(), format!("bytes={}-", offset)));
    req.headers
        .push(("Cache-Control".into(), "no-cache".into()));
    req.headers.push(("Accept-Encoding".into(), "identity".into()));
    let resp = send(&req, cache)?;
    let status = resp.status;
    if status == 416 {
        let mut plain = Req::new("GET", &route.endpoint);
        if let Ok(ip) = route.ip.parse() {
            plain.pin_ip = Some(ip);
        }
        if !route.dns.is_empty() {
            plain.pin_dns = Some(route.dns.clone());
        }
        plain.bind_ip = bind_ip;
        plain.bind_if = bind_if.to_string();
        plain.read_timeout = Duration::from_millis(2500);
        plain.connect_timeout = Duration::from_millis(4000);
        plain
            .headers
            .push(("Cache-Control".into(), "no-cache".into()));
        let mut r = send(&plain, cache)?;
        if !*reported_route {
            *reported_route = true;
            task.emit(json!({
                "type": "route", "idx": idx, "endpoint": route.endpoint,
                "ip": r.ip, "dns_ms": r.dns_ms, "dns_server": r.dns_server, "status": r.status
            }));
        }
        if r.status != 200 && r.status != 206 {
            return Err(format!("HTTP {}", r.status));
        }
        let mut buf = vec![0u8; buffer];
        loop {
            if cancel.load(Ordering::Relaxed) {
                return Ok(());
            }
            let n = match r.reader.read(&mut buf) {
                Ok(n) => n,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => return Ok(()),
                Err(e) => return Err(e.to_string()),
            };
            if n == 0 {
                return Ok(());
            }
            bytes.fetch_add(n as u64, Ordering::Relaxed);
        }
    }
    if !*reported_route {
        *reported_route = true;
        task.emit(json!({
            "type": "route", "idx": idx, "endpoint": route.endpoint,
            "ip": resp.ip, "dns_ms": resp.dns_ms, "dns_server": resp.dns_server, "status": resp.status
        }));
    }
    if status != 200 && status != 206 {
        return Err(format!("HTTP {}", status));
    }
    let mut r = resp;
    let mut buf = vec![0u8; buffer];
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Ok(());
        }
        let n = match r.reader.read(&mut buf) {
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => return Ok(()),
            Err(e) => return Err(e.to_string()),
        };
        if n == 0 {
            return Ok(());
        }
        bytes.fetch_add(n as u64, Ordering::Relaxed);
    }
}

fn upload_once(
    route: &SpeedRoute,
    body: &Arc<Vec<u8>>,
    cache: &ResolveCache,
    bytes: &Arc<AtomicU64>,
    bind_ip: Option<IpAddr>,
    bind_if: &str,
) -> Result<(), String> {
    let mut req = Req::new("POST", &route.endpoint);
    if let Ok(ip) = route.ip.parse() {
        req.pin_ip = Some(ip);
    }
    if !route.dns.is_empty() {
        req.pin_dns = Some(route.dns.clone());
    }
    req.bind_ip = bind_ip;
    req.bind_if = bind_if.to_string();
    req.read_timeout = Duration::from_millis(2500);
    req.connect_timeout = Duration::from_millis(4000);
    req.headers
        .push(("Content-Type".into(), "application/octet-stream".into()));
    req.headers
        .push(("Cache-Control".into(), "no-cache".into()));
    req.body = Some((**body).clone());
    let counter = bytes.clone();
    req.write_progress = Some(std::sync::Arc::new(move |n| {
        counter.fetch_add(n as u64, Ordering::Relaxed);
    }));
    let mut resp = send(&req, cache)?;
    let mut sink = vec![0u8; 64 * 1024];
    loop {
        match resp.reader.read(&mut sink) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }
    if resp.status == 200 || resp.status == 201 || resp.status == 204 {
        Ok(())
    } else {
        Err(format!("HTTP {}", resp.status))
    }
}

