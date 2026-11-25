//! 多 CDN / 多 DNS 并发吞吐测试引擎。
//!
//! 关键点：
//! - 每个 worker 独立线程、独立连接，按 endpoints 轮询分配（多 CDN）；
//! - DNS 由 ResolveCache 在配置的多个服务器间轮询（多 DNS），并记录命中服务器与解析耗时；
//! - Range 随机起点绕过 CDN 缓存，读到的每个字节都计入全局原子计数；
//! - 采样线程按 sample_ms 输出瞬时 Mbps，结束后给出稳态均值/峰值。

use crate::dns;
use crate::http::{parse_bind, parse_url, send, Req, ResolveCache};
use crate::{new_task, spawn_task, Task};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
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
    spawn_task(task, move |t| run(p, t));
    Ok(json!({"task_id": id}))
}

#[derive(Clone)]
struct SpeedRoute {
    endpoint: String,
    ip: String,
    dns: String,
    /// 该 IP 由第几台 DNS 解析得到；`usize::MAX` 表示没解析出来（交给系统解析）。
    dns_idx: usize,
}

/// 每个测速端点用「设置里的全部 DNS」并发解析，A/AAAA 都取；
/// 返回值按端点分组：worker 先均匀分配到各 CDN，再在组内轮换 IP。
/// 这样配置了几个 CDN 就用几个，不会被解析出更多 IP 的前几个端点“吃掉”所有线程。
fn build_routes(
    endpoints: &[String],
    servers: &[String],
    timeout: Duration,
    ip_mode: &str,
    dns_mode: &str,
) -> Vec<Vec<SpeedRoute>> {
    let servers = dns::dedupe_servers(servers);
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
            let mut servers = servers.clone();
            if dns_mode == "primary" && servers.len() > 1 {
                servers.truncate(1);
            }
            let host = host.clone();
            let ip_mode = ip_mode.to_string();
            handles.push(thread::spawn(move || {
                let answers = crate::dns::query_all(&host, &servers, qtype, timeout);
                // 把每条记录归因到具体 DNS，线程才能只拿“自己那台”解析出的 IP。
                let tagged: Vec<(crate::dns::Answer, usize)> = answers
                    .into_iter()
                    .map(|a| {
                        let idx = crate::dns::index_of(&servers, &a.server);
                        (a, idx)
                    })
                    .collect();
                (endpoint, tagged, ip_mode)
            }));
        }
    }
    let mut by_endpoint: HashMap<String, Vec<SpeedRoute>> = HashMap::new();
    for h in handles {
        if let Ok((endpoint, answers, ip_mode)) = h.join() {
            for (a, dns_idx) in answers {
                for ip in a.ips {
                    if (ip_mode == "v4" && !ip.is_ipv4()) || (ip_mode == "v6" && !ip.is_ipv6()) {
                        continue;
                    }
                    let ip = ip.to_string();
                    let list = by_endpoint.entry(endpoint.clone()).or_default();
                    // 按 (IP, DNS) 去重：两台 DNS 常解析到同一个 CDN IP，
                    // 保留各自的归属，线程才能真正按 DNS 分组。
                    if !list.iter().any(|r| r.ip == ip && r.dns_idx == dns_idx) {
                        list.push(SpeedRoute {
                            endpoint: endpoint.clone(),
                            ip,
                            dns: a.server.clone(),
                            dns_idx,
                        });
                    }
                }
            }
        }
    }
    let mut groups = Vec::with_capacity(endpoints.len());
    for endpoint in endpoints {
        let mut group = by_endpoint.remove(endpoint).unwrap_or_default();
        if group.is_empty() {
            // DNS 全部失败时仍保留端点，交给 ResolveCache 的系统解析兜底。
            group.push(SpeedRoute {
                endpoint: endpoint.clone(),
                ip: String::new(),
                dns: "自动".into(),
                dns_idx: usize::MAX,
            });
        }
        groups.push(group);
    }
    groups
}

/// 组内挑选路由：先只挑「自己首选 DNS」解析出的节点，按 `rank` 错开起点，
/// 组内轮完一轮后再滑到其它 DNS 的节点兜底，保证不同 worker 真的分散在不同 DNS 上。
fn pick_route(
    group: &[SpeedRoute],
    pref: Option<usize>,
    rank: usize,
    attempt: usize,
) -> &SpeedRoute {
    let n = group.len();
    if n == 1 {
        return &group[0];
    }
    let Some(p) = pref else {
        return &group[(rank + attempt) % n];
    };
    let own: Vec<usize> = (0..n).filter(|&i| group[i].dns_idx == p).collect();
    if !own.is_empty() {
        if attempt < own.len() {
            return &group[own[(rank + attempt) % own.len()]];
        }
        let rest: Vec<usize> = (0..n).filter(|&i| group[i].dns_idx != p).collect();
        if !rest.is_empty() {
            return &group[rest[(rank + attempt) % rest.len()]];
        }
        return &group[own[(rank + attempt) % own.len()]];
    }
    let rest: Vec<usize> = (0..n).filter(|&i| group[i].dns_idx != p).collect();
    &group[rest[(rank + attempt) % rest.len().max(1)]]
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
    let workers = p.workers.clamp(1, 32);
    // 参与分流的 DNS 列表：worker i 固定首选第 i % n 台。
    // 用下标列表而不是数量，某台 DNS 完全失败时分组也不会错位。
    let dns_used: Arc<Vec<usize>> = Arc::new({
        let mut idxs: Vec<usize> = routes
            .iter()
            .flatten()
            .filter(|r| r.dns_idx != usize::MAX)
            .map(|r| r.dns_idx)
            .collect();
        idxs.sort_unstable();
        idxs.dedup();
        idxs
    });
    let dns_total = dns_used.len();
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
        let bind_if = bind_if.clone();
        let dns_used = dns_used.clone();
        handles.push(thread::spawn(move || {
            worker(
                i, routes, mode, buffer, cache, bytes, errors, active, task, cancel, deadline,
                limit, bind_ip, bind_if, dns_used,
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
    let warm_ms = (p.duration_ms as f64 * 0.15).clamp(800.0, 4000.0) as u64;

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
        "dns_total": dns_total,
        "dns_servers": p.dns_servers,
        "cancelled": cancelled,
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
    routes: Arc<Vec<Vec<SpeedRoute>>>,
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
    dns_used: Arc<Vec<usize>>,
) {
    let endpoint_count = routes.len().max(1);
    // 每条线程固定一台首选 DNS，多 DNS 才会被真正用满而不是全挤在第一台。
    let pref = if dns_used.is_empty() {
        None
    } else {
        Some(dns_used[idx % dns_used.len()])
    };
    let first = routes
        .get(idx % endpoint_count)
        .and_then(|g| g.first())
        .map(|r| r.endpoint.clone())
        .unwrap_or_default();
    task.emit(json!({
        "type": "worker", "idx": idx, "endpoint": first, "state": "start", "dns_pref": pref
    }));
    let mut seed = (Instant::now().elapsed().as_nanos() as u64) ^ ((idx as u64) << 32) ^ 0x9E3779B97F4A7C15;
    // 记录上一次上报的出口，路由变化（换 DNS / 换 IP）时再发一条事件。
    let mut last_route: Option<(String, String)> = None;
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
        let endpoint_index = (idx + attempt) % endpoint_count;
        let group = &routes[endpoint_index];
        // 同一台 DNS 下的第几条线程，用来错开组内起始节点。
        let rank = idx / endpoint_count / dns_used.len().max(1);
        let route = pick_route(group, pref, rank, attempt).clone();
        let endpoint = route.endpoint.clone();
        attempt = attempt.wrapping_add(1);
        active.fetch_add(1, Ordering::Relaxed);
        let result = if mode == "upload" {
            upload_once(
                &route,
                body.as_ref().unwrap(),
                &cache,
                &bytes,
                bind_ip,
                bind_if.as_str(),
                pref,
            )
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
                &mut last_route,
                bind_ip,
                bind_if.as_str(),
                pref,
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
    last_route: &mut Option<(String, String)>,
    bind_ip: Option<IpAddr>,
    bind_if: &str,
    dns_pref: Option<usize>,
) -> Result<(), String> {
    let offset = rnd(seed) % 1_000_000_000;
    let mut req = Req::new("GET", &route.endpoint);
    if let Ok(ip) = route.ip.parse() {
        req.pin_ip = Some(ip);
    }
    if !route.dns.is_empty() {
        req.pin_dns = Some(route.dns.clone());
    }
    req.dns_pref = dns_pref;
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
        plain.dns_pref = dns_pref;
        plain.bind_ip = bind_ip;
        plain.bind_if = bind_if.to_string();
        plain.read_timeout = Duration::from_millis(2500);
        plain.connect_timeout = Duration::from_millis(4000);
        plain
            .headers
            .push(("Cache-Control".into(), "no-cache".into()));
        let mut r = send(&plain, cache)?;
        report_route(idx, route, &r, task, last_route, dns_pref);
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
    report_route(idx, route, &resp, task, last_route, dns_pref);
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

/// 上报某条线程当前的出口（IP + 实际命中的 DNS），路由变化时才发事件。
fn report_route(
    idx: usize,
    route: &SpeedRoute,
    r: &crate::http::Response,
    task: &Arc<Task>,
    last: &mut Option<(String, String)>,
    dns_pref: Option<usize>,
) {
    let now = (r.ip.clone(), r.dns_server.clone());
    if last.as_ref() == Some(&now) {
        return;
    }
    *last = Some(now);
    task.emit(json!({
        "type": "route", "idx": idx, "endpoint": route.endpoint,
        "ip": r.ip, "dns_ms": r.dns_ms, "dns_server": r.dns_server, "status": r.status,
        "dns_pref": dns_pref, "cdn_ip": route.ip
    }));
}

fn upload_once(
    route: &SpeedRoute,
    body: &Arc<Vec<u8>>,
    cache: &ResolveCache,
    bytes: &Arc<AtomicU64>,
    bind_ip: Option<IpAddr>,
    bind_if: &str,
    dns_pref: Option<usize>,
) -> Result<(), String> {
    let mut req = Req::new("POST", &route.endpoint);
    if let Ok(ip) = route.ip.parse() {
        req.pin_ip = Some(ip);
    }
    if !route.dns.is_empty() {
        req.pin_dns = Some(route.dns.clone());
    }
    req.dns_pref = dns_pref;
    req.bind_ip = bind_ip;
    req.bind_if = bind_if.to_string();
    req.read_timeout = Duration::from_millis(2500);
    req.connect_timeout = Duration::from_millis(4000);
    req.headers
        .push(("Content-Type".into(), "application/octet-stream".into()));
    req.headers
        .push(("Cache-Control".into(), "no-cache".into()));
    req.headers
        .push(("Content-Length".into(), body.len().to_string()));
    req.headers.push(("Connection".into(), "close".into()));
    req.body = Some(body.clone());
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


#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn pick_route_prefers_own_dns() {
        let group = vec![
            SpeedRoute { endpoint: "e".into(), ip: "1.1.1.1".into(), dns: "a".into(), dns_idx: 0 },
            SpeedRoute { endpoint: "e".into(), ip: "2.2.2.2".into(), dns: "b".into(), dns_idx: 1 },
            SpeedRoute { endpoint: "e".into(), ip: "3.3.3.3".into(), dns: "a".into(), dns_idx: 0 },
            SpeedRoute { endpoint: "e".into(), ip: String::new(), dns: "自动".into(), dns_idx: usize::MAX },
        ];
        // 首选 DNS 0 有两条节点：前两次尝试只在组内换，且按 rank 错开。
        assert_eq!(pick_route(&group, Some(0), 0, 0).ip, "1.1.1.1");
        assert_eq!(pick_route(&group, Some(0), 1, 0).ip, "3.3.3.3");
        // 首选 DNS 1 只有一条：第一次命中，之后滑到其它 DNS 兜底。
        assert_eq!(pick_route(&group, Some(1), 0, 0).ip, "2.2.2.2");
        assert_ne!(pick_route(&group, Some(1), 0, 1).ip, "2.2.2.2");
        // 没有自定义 DNS：整组轮转。
        assert_eq!(pick_route(&group, None, 0, 3).ip, "");
    }

    /// 真实网络验证：多条 worker 会分散到不同 DNS。需要外网，默认跳过。
    #[test]
    #[ignore]
    fn live_speed_spreads_across_dns() {
        let r = start(json!({
            "mode": "download",
            "endpoints": ["https://proof.ovh.net/files/10Mb.dat"],
            "dns_servers": ["223.5.5.5", "119.29.29.29"],
            "workers": 4,
            "duration_ms": 4000,
            "sample_ms": 400,
            "timeout_ms": 4000,
        }))
        .expect("测速应能启动");
        let id = r["task_id"].as_str().unwrap().to_string();
        thread::sleep(Duration::from_millis(2600));
        let task = crate::get_task(&id).unwrap();
        let events = task.events.lock().unwrap().clone();
        let mut prefs = HashSet::new();
        let mut servers = HashSet::new();
        for e in &events {
            if e["type"] == "route" {
                if let Some(p) = e["dns_pref"].as_i64() {
                    prefs.insert(p);
                }
                if let Some(s) = e["dns_server"].as_str() {
                    servers.insert(s.to_string());
                }
            }
        }
        println!("dns_pref={:?} dns_server={:?}", prefs, servers);
        assert!(!prefs.is_empty(), "应至少有一条连接上报出口");
        assert!(prefs.len() >= 2 || servers.len() <= 1, "worker 应分散到多台 DNS");
        // 等测速收尾，确保采样线程正常结束。
        for _ in 0..40 {
            if *task.status.lock().unwrap() != "running" {
                break;
            }
            thread::sleep(Duration::from_millis(300));
        }
        let summary = task.summary.lock().unwrap().clone().unwrap_or(Value::Null);
        println!("summary={}", summary);
        assert!(summary["total_bytes"].as_u64().unwrap_or(0) > 0);
        assert!(summary["dns_total"].as_u64().unwrap_or(0) >= 1);
    }
}
