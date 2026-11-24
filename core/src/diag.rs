//! 网络诊断：DNS 对照查询、TCP Ping、STUN NAT 类型、路由追踪、iperf3 进程托管。

use crate::dns;
use crate::http::ResolveCache;
use crate::{new_task, spawn_task, Task};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, UdpSocket};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

// ---------------- DNS 对照查询 ----------------

#[derive(Deserialize)]
#[serde(default)]
struct DnsParams {
    host: String,
    servers: Vec<String>,
    timeout_ms: u64,
    qtype: String,
}

impl Default for DnsParams {
    fn default() -> Self {
        Self {
            host: String::new(),
            servers: vec!["223.5.5.5".into(), "119.29.29.29".into()],
            timeout_ms: 3000,
            qtype: "BOTH".into(),
        }
    }
}

pub fn start_dns(args: Value) -> Result<Value, String> {
    let p: DnsParams = serde_json::from_value(args).map_err(|e| e.to_string())?;
    if p.host.trim().is_empty() {
        return Err("请输入域名".into());
    }
    let (id, task) = new_task("dns");
    spawn_task(task, move |task| {
        let host = p.host.trim().to_string();
        let timeout = Duration::from_millis(p.timeout_ms.clamp(500, 20000));
        task.emit(json!({"type": "start", "host": host, "servers": p.servers}));
        let mut all = Vec::new();
        for server in &p.servers {
            for (label, qtype) in [("A", 1u16), ("AAAA", 28u16)] {
                if p.qtype == "A" && qtype == 28 {
                    continue;
                }
                if p.qtype == "AAAA" && qtype == 1 {
                    continue;
                }
                match dns::query(&host, server, qtype, timeout) {
                    Ok(a) => {
                        let ips: Vec<String> = a.ips.iter().map(|ip| ip.to_string()).collect();
                        task.emit(json!({
                            "type": "result", "server": server, "record": label,
                            "ips": ips, "ms": a.elapsed_ms, "rcode": a.rcode, "truncated": a.truncated,
                        }));
                        all.push(json!({"server": server, "record": label, "ips": ips, "ms": a.elapsed_ms, "truncated": a.truncated}));
                    }
                    Err(e) => {
                        task.emit(json!({"type": "error", "server": server, "record": label, "message": e}));
                    }
                }
            }
        }
        task.emit(json!({"type": "done", "results": all}));
        task.finish("done", json!({"results": all}));
    });
    Ok(json!({"task_id": id}))
}

// ---------------- TCP Ping ----------------

#[derive(Deserialize)]
#[serde(default)]
struct PingParams {
    target: String,
    port: u16,
    count: u32,
    interval_ms: u64,
    timeout_ms: u64,
    dns_servers: Vec<String>,
}

impl Default for PingParams {
    fn default() -> Self {
        Self {
            target: String::new(),
            port: 443,
            count: 10,
            interval_ms: 800,
            timeout_ms: 3000,
            dns_servers: vec!["223.5.5.5".into(), "119.29.29.29".into()],
        }
    }
}

pub fn start_ping(args: Value) -> Result<Value, String> {
    let p: PingParams = serde_json::from_value(args).map_err(|e| e.to_string())?;
    if p.target.trim().is_empty() {
        return Err("请输入目标地址".into());
    }
    let (id, task) = new_task("ping");
    spawn_task(task, move |task| {
        let t = task.clone();
        let cache = ResolveCache::new(
            p.dns_servers.clone(),
            Duration::from_millis(p.timeout_ms.clamp(1000, 20000)),
        );
        let target = p.target.trim().to_string();
        let (ips, dns_server, dns_ms) = match cache.resolve(&target) {
            Ok(v) => v,
            Err(e) => {
                task.emit(json!({"type": "error", "message": e}));
                task.finish("error", json!({"error": e}));
                return;
            }
        };
        let ip = ips[0];
        task.emit(json!({"type": "resolve", "ip": ip.to_string(), "dns_server": dns_server, "dns_ms": dns_ms}));
        let total = if p.count == 0 { 100000 } else { p.count };
        let mut seq = 0u32;
        let mut ok = 0u32;
        let mut rtts: Vec<f64> = Vec::new();
        while seq < total && !t.is_cancelled() {
            seq += 1;
            let start = Instant::now();
            match TcpStream::connect_timeout(
                &SocketAddr::new(ip, p.port),
                Duration::from_millis(p.timeout_ms.clamp(200, 30000)),
            ) {
                Ok(_) => {
                    let ms = start.elapsed().as_secs_f64() * 1000.0;
                    ok += 1;
                    rtts.push(ms);
                    task.emit(json!({"type": "sample", "seq": seq, "ok": true, "ms": (ms * 100.0).round() / 100.0}));
                }
                Err(e) => {
                    task.emit(json!({"type": "sample", "seq": seq, "ok": false, "ms": null, "error": e.to_string()}));
                }
            }
            if seq < total {
                thread::sleep(Duration::from_millis(p.interval_ms.clamp(50, 5000)));
            }
        }
        let avg = if rtts.is_empty() { 0.0 } else { rtts.iter().sum::<f64>() / rtts.len() as f64 };
        let min = rtts.iter().cloned().fold(f64::INFINITY, f64::min);
        let max = rtts.iter().cloned().fold(0.0f64, f64::max);
        let jitter = if rtts.len() > 1 {
            rtts.windows(2).map(|w| (w[1] - w[0]).abs()).sum::<f64>() / (rtts.len() - 1) as f64
        } else {
            0.0
        };
        let loss = if seq == 0 { 0.0 } else { (seq - ok) as f64 / seq as f64 * 100.0 };
        let summary = json!({
            "target": target, "ip": ip.to_string(), "port": p.port,
            "sent": seq, "received": ok,
            "loss": (loss * 100.0).round() / 100.0,
            "min": if min.is_finite() { (min * 100.0).round() / 100.0 } else { 0.0 },
            "avg": (avg * 100.0).round() / 100.0,
            "max": (max * 100.0).round() / 100.0,
            "jitter": (jitter * 100.0).round() / 100.0,
        });
        task.emit(json!({"type": "done", "summary": summary}));
        task.finish("done", summary);
    });
    Ok(json!({"task_id": id}))
}

// ---------------- STUN NAT ----------------

#[derive(Deserialize)]
#[serde(default)]
struct NatParams {
    servers: Vec<String>,
    timeout_ms: u64,
    dns_servers: Vec<String>,
}

impl Default for NatParams {
    fn default() -> Self {
        Self {
            servers: vec![
                "stun.cloudflare.com:3478".into(),
                "stun.l.google.com:19302".into(),
                "stun1.l.google.com:19302".into(),
                "stun.nextcloud.com:3478".into(),
                "stun.sipgate.net:3478".into(),
                "stun.voipbuster.com:3478".into(),
                "stun.miwifi.com:3478".into(),
            ],
            timeout_ms: 3000,
            dns_servers: vec!["223.5.5.5".into(), "119.29.29.29".into()],
        }
    }
}

fn stun_query(sock: &UdpSocket, dest: SocketAddr, timeout: Duration) -> Result<SocketAddr, String> {
    let mut txid = [0u8; 12];
    let seed = Instant::now().elapsed().as_nanos() as u64;
    for (i, b) in txid.iter_mut().enumerate() {
        *b = ((seed >> (i % 8 * 8)) & 0xFF) as u8 ^ (i as u8 * 31);
    }
    let mut req = [0u8; 20];
    req[0] = 0x00;
    req[1] = 0x01;
    req[4..8].copy_from_slice(&[0x21, 0x12, 0xA4, 0x42]);
    req[8..20].copy_from_slice(&txid);
    sock.send_to(&req, dest).map_err(|e| e.to_string())?;
    sock.set_read_timeout(Some(timeout)).ok();
    let start = Instant::now();
    loop {
        let mut buf = [0u8; 512];
        let (n, _) = sock.recv_from(&mut buf).map_err(|e| e.to_string())?;
        if n < 20 {
            continue;
        }
        if buf[4..8] != [0x21, 0x12, 0xA4, 0x42] || buf[8..20] != txid {
            continue;
        }
        let mut pos = 20usize;
        while pos + 4 <= n {
            let atype = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
            let alen = u16::from_be_bytes([buf[pos + 2], buf[pos + 3]]) as usize;
            let body = &buf[pos + 4..(pos + 4 + alen).min(n)];
            if (atype == 0x0020 || atype == 0x0001) && body.len() >= 8 {
                let family = body[1];
                let xport = u16::from_be_bytes([body[2], body[3]]);
                let port = if atype == 0x0020 { xport ^ 0x2112 } else { xport };
                let ip = if family == 0x01 && body.len() >= 8 {
                    let mut oct = [0u8; 4];
                    for i in 0..4 {
                        oct[i] = if atype == 0x0020 {
                            body[4 + i] ^ [0x21, 0x12, 0xA4, 0x42][i]
                        } else {
                            body[4 + i]
                        };
                    }
                    IpAddr::V4(Ipv4Addr::from(oct))
                } else if family == 0x02 && body.len() >= 20 {
                    let mut oct = [0u8; 16];
                    let mut mask = [0u8; 16];
                    mask[..4].copy_from_slice(&[0x21, 0x12, 0xA4, 0x42]);
                    mask[4..].copy_from_slice(&txid);
                    for i in 0..16 {
                        oct[i] = if atype == 0x0020 {
                            body[4 + i] ^ mask[i]
                        } else {
                            body[4 + i]
                        };
                    }
                    IpAddr::V6(Ipv6Addr::from(oct))
                } else {
                    continue;
                };
                let _ = start;
                return Ok(SocketAddr::new(ip, port));
            }
            pos += 4 + alen;
        }
    }
}

fn parse_host_port(s: &str, default_port: u16) -> (String, u16) {
    let s = s.trim();
    if s.starts_with('[') {
        if let Some(end) = s.find(']') {
            let host = s[1..end].to_string();
            let port = s[end + 1..]
                .strip_prefix(':')
                .and_then(|p| p.parse().ok())
                .unwrap_or(default_port);
            return (host, port);
        }
    }
    if s.matches(':').count() == 1 {
        let (h, p) = s.split_once(':').unwrap();
        return (h.to_string(), p.parse().unwrap_or(default_port));
    }
    (s.to_string(), default_port)
}

pub fn start_nat(args: Value) -> Result<Value, String> {
    let p: NatParams = serde_json::from_value(args).map_err(|e| e.to_string())?;
    let (id, task) = new_task("nat");
    spawn_task(task, move |task| {
        let t = task.clone();
        // 多 STUN 源顺序探测，单台超时压到 1.5s，避免不可达节点拖慢整体。
        let timeout = Duration::from_millis(p.timeout_ms.clamp(500, 1500));
        let cache = ResolveCache::new(p.dns_servers.clone(), timeout);
        let mut dests = Vec::new();
        for s in &p.servers {
            let (host, port) = parse_host_port(s, 3478);
            match cache.resolve(&host) {
                Ok((ips, _, _)) => dests.push((s.clone(), SocketAddr::new(ips[0], port))),
                Err(e) => task.emit(json!({"type": "error", "server": s, "message": e})),
            }
        }
        if dests.is_empty() {
            let msg = "STUN 服务器不可用".to_string();
            task.finish("error", json!({"error": msg}));
            return;
        }
        let sock_a = match UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => {
                task.finish("error", json!({"error": e.to_string()}));
                return;
            }
        };
        let mut mappings: Vec<(String, SocketAddr)> = Vec::new();
        let mut last_ms = 0u128;
        for (name, dest) in &dests {
            let start = Instant::now();
            match stun_query(&sock_a, *dest, timeout) {
                Ok(m) => {
                    last_ms = start.elapsed().as_millis();
                    task.emit(json!({"type": "mapping", "server": name, "public": m.to_string(), "ms": last_ms}));
                    mappings.push((name.clone(), m));
                }
                Err(e) => task.emit(json!({"type": "error", "server": name, "message": e})),
            }
            if t.is_cancelled() {
                return;
            }
        }
        // 同一 socket 再查一次第一个「成功」服务器，判断端口是否稳定。
        let mut stable = None;
        let first_dest = mappings.first().map(|(_, d)| *d);
        if let Some(fd) = first_dest {
            if let Ok(m2) = stun_query(&sock_a, fd, timeout) {
                stable = Some(m2 == mappings[0].1);
                task.emit(json!({"type": "stability", "stable": stable.unwrap_or(false), "public": m2.to_string()}));
            }
        }
        let sock_b = UdpSocket::bind("0.0.0.0:0").ok();
        let mut alt_port = None;
        if let (Some(sb), Some(fd)) = (sock_b, first_dest) {
            if let Ok(m4) = stun_query(&sb, fd, timeout) {
                alt_port = Some(m4);
                task.emit(json!({"type": "local_port_change", "public": m4.to_string()}));
            }
        }
        let same_across = mappings.len() >= 2
            && mappings.iter().all(|(_, m)| {
                m.ip() == mappings[0].1.ip() && m.port() == mappings[0].1.port()
            });
        let mapping_behavior = if mappings.is_empty() {
            "未知"
        } else if same_across {
            "端点无关映射（EIM）"
        } else {
            "地址/端口相关映射（对称型）"
        };
        let nat_type = if mappings.is_empty() {
            "未知"
        } else if same_across && stable.unwrap_or(false) {
            "完全锥形 / 限制锥形（可打洞）"
        } else if same_across {
            "端口受限锥形（端口稳定）"
        } else {
            "对称型 NAT（Symmetry，难打洞）"
        };
        let summary = json!({
            "public": mappings.first().map(|(_, m)| m.to_string()).unwrap_or_default(),
            "mapping_behavior": mapping_behavior,
            "filtering_behavior": "未测试（需对端配合）",
            "nat_type": nat_type,
            "stable_port": stable,
            "alt_local_port": alt_port.map(|m| m.to_string()),
            "servers": mappings.iter().map(|(s, m)| json!({"server": s, "public": m.to_string()})).collect::<Vec<_>>(),
            "latency_ms": last_ms,
        });
        task.emit(json!({"type": "done", "summary": summary}));
        task.finish("done", summary);
    });
    Ok(json!({"task_id": id}))
}

// ---------------- 路由追踪（UDP + IP_RECVERR） ----------------

#[derive(Deserialize)]
#[serde(default)]
struct TraceParams {
    target: String,
    max_hops: u32,
    timeout_ms: u64,
}

impl Default for TraceParams {
    fn default() -> Self {
        Self {
            target: String::new(),
            max_hops: 30,
            timeout_ms: 2000,
        }
    }
}

pub fn start_trace(args: Value) -> Result<Value, String> {
    let p: TraceParams = serde_json::from_value(args).map_err(|e| e.to_string())?;
    let target: IpAddr = p
        .target
        .trim()
        .parse()
        .map_err(|_| "请输入已解析的数字 IP 地址（IPv4/IPv6）".to_string())?;
    let (id, task) = new_task("trace");
    spawn_task(task, move |task| {
        let result = match target {
            IpAddr::V4(v4) => trace_v4(v4, p.max_hops.clamp(1, 64), p.timeout_ms.clamp(300, 10000), &task),
            IpAddr::V6(_) => Err("IPv6 路由追踪暂未开放".to_string()),
        };
        if task.is_cancelled() {
            // 用户已停止：不要再用 done 覆盖 cancelling / cancelled 状态。
            let summary = json!({"target": target.to_string(), "cancelled": true, "hops": []});
            task.emit(json!({"type": "done", "summary": summary}));
            task.finish("cancelled", summary);
            return;
        }
        match result {
            Ok(hops) => {
                let summary = json!({"target": target.to_string(), "hops": hops});
                task.emit(json!({"type": "done", "summary": summary}));
                task.finish("done", summary);
            }
            Err(e) => {
                task.emit(json!({"type": "error", "message": e}));
                task.finish("error", json!({"error": e}));
            }
        }
    });
    Ok(json!({"task_id": id}))
}

fn trace_v4(
    target: Ipv4Addr,
    max_hops: u32,
    timeout_ms: u64,
    task: &Arc<Task>,
) -> Result<Vec<Value>, String> {
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0);
        if fd < 0 {
            return Err("socket 创建失败".into());
        }
        let on: libc::c_int = 1;
        if libc::setsockopt(
            fd,
            libc::IPPROTO_IP,
            libc::IP_RECVERR,
            &on as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        ) < 0
        {
            libc::close(fd);
            return Err("设备内核不允许 IP_RECVERR（需 root 或 ROM 支持）".into());
        }
        let mut hops = Vec::new();
        for ttl in 1..=max_hops {
            if task.is_cancelled() {
                break;
            }
            let ttl_c: libc::c_int = ttl as i32;
            libc::setsockopt(
                fd,
                libc::IPPROTO_IP,
                libc::IP_TTL,
                &ttl_c as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
            let mut dest: libc::sockaddr_in = std::mem::zeroed();
            dest.sin_family = libc::AF_INET as u16;
            dest.sin_port = (33434u16 + ttl as u16).to_be();
            dest.sin_addr.s_addr = u32::from_ne_bytes(target.octets());
            let start = Instant::now();
            let payload = [0u8; 1];
            libc::sendto(
                fd,
                payload.as_ptr() as *const libc::c_void,
                1,
                0,
                &dest as *const _ as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            );
            let mut hop_ip: Option<Ipv4Addr> = None;
            let mut reached = false;
            let mut rtt = 0f64;
            // poll 等待错误队列
            let mut pfd = libc::pollfd {
                fd,
                events: libc::POLLIN | libc::POLLERR,
                revents: 0,
            };
            let deadline = Instant::now() + Duration::from_millis(timeout_ms);
            let mut ready = 0;
            loop {
                if task.is_cancelled() {
                    break;
                }
                let remain = deadline.saturating_duration_since(Instant::now());
                let slice = remain.as_millis().min(100) as i32;
                if slice <= 0 {
                    break;
                }
                ready = libc::poll(&mut pfd, 1, slice);
                if ready > 0 || remain.is_zero() {
                    break;
                }
            }
            if task.is_cancelled() {
                libc::close(fd);
                return Ok(hops);
            }
            if ready > 0 {
                let mut msg: libc::msghdr = std::mem::zeroed();
                let mut data = [0u8; 512];
                let mut iov = libc::iovec {
                    iov_base: data.as_mut_ptr() as *mut libc::c_void,
                    iov_len: data.len(),
                };
                msg.msg_iov = &mut iov;
                msg.msg_iovlen = 1;
                let mut control = [0u8; 512];
                msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
                msg.msg_controllen = control.len() as _;
                let n = libc::recvmsg(fd, &mut msg, libc::MSG_ERRQUEUE);
                if n >= 0 {
                    rtt = start.elapsed().as_secs_f64() * 1000.0;
                    let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
                    while !cmsg.is_null() {
                        if (*cmsg).cmsg_level == libc::IPPROTO_IP
                            && (*cmsg).cmsg_type == libc::IP_RECVERR
                        {
                            let ee = libc::CMSG_DATA(cmsg) as *const libc::sock_extended_err;
                            let origin = (*ee).ee_origin;
                            if origin == libc::SO_EE_ORIGIN_ICMP
                                || origin == libc::SO_EE_ORIGIN_ICMP6
                            {
                                let sa = (ee as *const u8)
                                    .add(std::mem::size_of::<libc::sock_extended_err>())
                                    as *const libc::sockaddr_in;
                                if (*sa).sin_family == libc::AF_INET as u16 {
                                    let oct = (*sa).sin_addr.s_addr.to_ne_bytes();
                                    let ip = Ipv4Addr::from(oct);
                                    hop_ip = Some(ip);
                                    if ip == target
                                        || (*ee).ee_errno == libc::ECONNREFUSED as u32
                                    {
                                        reached = true;
                                    }
                                }
                            }
                        }
                        cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
                    }
                }
                if hop_ip.is_none() {
                    // 普通回包，说明到达目标
                    let n2 = libc::recv(fd, data.as_mut_ptr() as *mut libc::c_void, 512, 0);
                    if n2 >= 0 {
                        hop_ip = Some(target);
                        reached = true;
                        rtt = start.elapsed().as_secs_f64() * 1000.0;
                    }
                }
            }
            let ms = (rtt * 100.0).round() / 100.0;
            let hop = match hop_ip {
                Some(ip) => json!({"ttl": ttl, "ip": ip.to_string(), "ms": ms, "reached": reached}),
                None => json!({"ttl": ttl, "ip": "*", "ms": null, "reached": false}),
            };
            hops.push(hop.clone());
            task.emit(json!({"type": "hop", "hop": hop}));
            if reached {
                break;
            }
        }
        libc::close(fd);
        Ok(hops)
    }
}

// ---------------- iperf3 托管 ----------------

#[derive(Deserialize)]
#[serde(default)]
struct IperfParams {
    bin: String,
    args: Vec<String>,
    cwd: Option<String>,
}

impl Default for IperfParams {
    fn default() -> Self {
        Self {
            bin: String::new(),
            args: vec!["-s".into(), "-p".into(), "5201".into()],
            cwd: None,
        }
    }
}

pub fn start_iperf(args: Value) -> Result<Value, String> {
    let p: IperfParams = serde_json::from_value(args).map_err(|e| e.to_string())?;
    if p.bin.is_empty() {
        return Err("iperf3 可执行文件路径为空".into());
    }
    let (id, task) = new_task("iperf");
    spawn_task(task, move |task| {
        let t = task.clone();
        let mut cmd = Command::new(&p.bin);
        cmd.args(&p.args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(c) = &p.cwd {
            cmd.current_dir(c);
        }
        match cmd.spawn() {
            Ok(mut child) => {
                let stdout = child.stdout.take();
                let stderr = child.stderr.take();
                let mut threads = Vec::new();
                if let Some(out) = stdout {
                    let t = t.clone();
                    threads.push(thread::spawn(move || {
                        let reader = BufReader::new(out);
                        for line in reader.lines().map_while(Result::ok) {
                            t.emit(json!({"type": "line", "stream": "stdout", "line": line}));
                        }
                    }));
                }
                if let Some(err) = stderr {
                    let t = t.clone();
                    threads.push(thread::spawn(move || {
                        let reader = BufReader::new(err);
                        for line in reader.lines().map_while(Result::ok) {
                            t.emit(json!({"type": "line", "stream": "stderr", "line": line}));
                        }
                    }));
                }
                let code = child.wait().map(|s| s.code().unwrap_or(-1)).unwrap_or(-1);
                for th in threads {
                    let _ = th.join();
                }
                let summary = json!({"exit_code": code, "args": p.args});
                t.emit(json!({"type": "exit", "code": code}));
                t.finish("done", summary);
            }
            Err(e) => {
                let msg = format!("无法启动 iperf3: {}", e);
                t.emit(json!({"type": "error", "message": msg}));
                t.finish("error", json!({"error": msg}));
            }
        }
    });
    Ok(json!({"task_id": id}))
}
