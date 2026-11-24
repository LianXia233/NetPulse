//! 极简 DNS 客户端（UDP + TCP 回退），支持自定义服务器、多服务器竞速、A/AAAA 查询。
//! 不依赖系统 resolver，便于「多 DNS 解析」对照测速。

use std::collections::HashSet;
use std::io::{Read, Write};
use std::sync::mpsc;
use std::thread;
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Answer {
    pub ips: Vec<IpAddr>,
    pub elapsed_ms: u128,
    pub server: String,
    pub rcode: u16,
    pub truncated: bool,
}

fn encode_name(name: &str, out: &mut Vec<u8>) {
    for part in name.trim_end_matches('.').split('.') {
        let bytes = part.as_bytes();
        out.push(bytes.len() as u8);
        out.extend_from_slice(bytes);
    }
    out.push(0);
}

/// 去掉空白、空项和重复 DNS；DoH/DoT 按大小写不敏感去重，保留首次出现的写法。
fn server_key(value: &str) -> String {
    let mut key = value.trim().to_ascii_lowercase();
    if let Some(rest) = key.strip_prefix("tls://") {
        key = format!("dot://{}", rest);
    }
    if key.starts_with("dot://") {
        key = key.trim_end_matches('/').to_string();
        if let Some(rest) = key.strip_prefix("dot://") {
            if let Some(host) = rest.strip_suffix(":853") {
                key = format!("dot://{}", host);
            }
        }
    } else if key.starts_with("https://") {
        key = key.trim_end_matches('/').to_string();
    } else if let Some(host) = key.strip_suffix(":53") {
        key = host.to_string();
    }
    key
}

pub fn dedupe_servers(servers: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(servers.len());
    for server in servers {
        let value = server.trim();
        if value.is_empty() || value.starts_with('#') {
            continue;
        }
        if seen.insert(server_key(value)) {
            out.push(value.to_string());
        }
    }
    out
}

pub fn parse_server(server: &str) -> Result<(IpAddr, u16), String> {
    let s = server.trim();
    if let Ok(ip) = s.parse::<IpAddr>() {
        return Ok((ip, 53));
    }
    if s.starts_with('[') {
        if let Some(end) = s.find(']') {
            let ip: IpAddr = s[1..end].parse().map_err(|_| "DNS 服务器地址无效")?;
            let port = if s[end + 1..].starts_with(':') {
                s[end + 2..].parse().unwrap_or(53)
            } else {
                53
            };
            return Ok((ip, port));
        }
    }
    if s.matches(':').count() == 1 {
        let (h, p) = s.split_once(':').unwrap();
        let ip: IpAddr = h.parse().map_err(|_| "DNS 服务器地址无效")?;
        return Ok((ip, p.parse().unwrap_or(53)));
    }
    s.parse::<IpAddr>()
        .map(|ip| (ip, 53))
        .map_err(|_| "DNS 服务器地址无效".to_string())
}

fn build_query(host: &str, qtype: u16, id: u16) -> Vec<u8> {
    let mut pkt = Vec::with_capacity(64);
    pkt.extend_from_slice(&id.to_be_bytes());
    // RD=1, opcode 0
    pkt.extend_from_slice(&[0x01, 0x00]);
    pkt.extend_from_slice(&[0x00, 0x01]); // qdcount
    pkt.extend_from_slice(&[0x00, 0x00]);
    pkt.extend_from_slice(&[0x00, 0x00]);
    pkt.extend_from_slice(&[0x00, 0x00]);
    encode_name(host, &mut pkt);
    pkt.extend_from_slice(&qtype.to_be_bytes());
    pkt.extend_from_slice(&[0x00, 0x01]);
    pkt
}

fn skip_name(buf: &[u8], mut pos: usize) -> Result<usize, String> {
    loop {
        if pos >= buf.len() {
            return Err("DNS 报文截断".into());
        }
        let b = buf[pos];
        if b == 0 {
            return Ok(pos + 1);
        }
        if b & 0xC0 == 0xC0 {
            // 压缩指针，占两字节
            return Ok(pos + 2);
        }
        pos += 1 + b as usize;
    }
}

fn parse_response(buf: &[u8], want: u16, expect_id: Option<u16>) -> Result<(Vec<IpAddr>, u16, bool), String> {
    if buf.len() < 12 {
        return Err("DNS 响应过短".into());
    }
    if let Some(id) = expect_id {
        if u16::from_be_bytes([buf[0], buf[1]]) != id {
            return Err("DNS 响应 ID 不匹配".into());
        }
    }
    let flags = u16::from_be_bytes([buf[2], buf[3]]);
    let rcode = flags & 0x000F;
    let truncated = flags & 0x0200 != 0;
    let qd = u16::from_be_bytes([buf[4], buf[5]]) as usize;
    let an = u16::from_be_bytes([buf[6], buf[7]]) as usize;
    let mut pos = 12;
    for _ in 0..qd {
        pos = skip_name(buf, pos)?;
        pos += 4;
    }
    let mut ips = Vec::new();
    for _ in 0..an {
        pos = skip_name(buf, pos)?;
        if pos + 10 > buf.len() {
            break;
        }
        let rtype = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
        let rdlen = u16::from_be_bytes([buf[pos + 8], buf[pos + 9]]) as usize;
        pos += 10;
        if pos + rdlen > buf.len() {
            break;
        }
        if rtype == want {
            match (rtype, rdlen) {
                (1, 4) => {
                    let ip = IpAddr::V4(std::net::Ipv4Addr::new(
                        buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3],
                    ));
                    ips.push(ip);
                }
                (28, 16) => {
                    let mut oct = [0u8; 16];
                    oct.copy_from_slice(&buf[pos..pos + 16]);
                    ips.push(IpAddr::V6(std::net::Ipv6Addr::from(oct)));
                }
                _ => {}
            }
        }
        pos += rdlen;
    }
    Ok((ips, rcode, truncated))
}

fn split_dot_spec(server: &str) -> (String, u16) {
    let raw = server
        .strip_prefix("dot://")
        .or_else(|| server.strip_prefix("tls://"))
        .or_else(|| server.strip_prefix("DOT://"))
        .or_else(|| server.strip_prefix("TLS://"))
        .unwrap_or(server)
        .trim()
        .trim_end_matches('/');
    if raw.starts_with('[') {
        if let Some(end) = raw.find(']') {
            let host = raw[1..end].to_string();
            let port = raw[end + 1..]
                .strip_prefix(':')
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or(853);
            return (host, port);
        }
    }
    if raw.matches(':').count() == 1 {
        if let Some((host, port)) = raw.rsplit_once(':') {
            if let Ok(p) = port.parse::<u16>() {
                return (host.to_string(), p);
            }
        }
    }
    (raw.to_string(), 853)
}

fn query_dot(host: &str, server: &str, qtype: u16, timeout: Duration) -> Result<Answer, String> {
    let (name, port) = split_dot_spec(server);
    if name.is_empty() {
        return Err("DoT 服务器地址为空".into());
    }
    let addrs: Vec<IpAddr> = if let Ok(ip) = name.parse::<IpAddr>() {
        vec![ip]
    } else {
        (name.as_str(), port)
            .to_socket_addrs()
            .map_err(|e| format!("DoT 域名解析 {} 失败: {}", name, e))?
            .map(|a| a.ip())
            .collect()
    };
    if addrs.is_empty() {
        return Err(format!("DoT 域名无地址: {}", name));
    }
    let start = Instant::now();
    let id = (start.elapsed().as_nanos() as u16) ^ 0x6B6B;
    let pkt = build_query(host, qtype, id);
    let mut last = String::from("DoT 连接失败");
    for ip in addrs {
        match crate::http::tls_connect(&name, ip, port, timeout) {
            Ok(mut conn) => {
                let frame = (pkt.len() as u16).to_be_bytes();
                if let Err(e) = conn.write_all(&frame).and_then(|_| conn.write_all(&pkt)) {
                    last = format!("DoT 写入失败: {}", e);
                    continue;
                }
                let mut len_buf = [0u8; 2];
                if let Err(e) = conn.read_exact(&mut len_buf) {
                    last = format!("DoT 读取长度失败: {}", e);
                    continue;
                }
                let len = u16::from_be_bytes(len_buf) as usize;
                if len == 0 || len > 65535 {
                    last = format!("DoT 响应长度异常: {}", len);
                    continue;
                }
                let mut buf = vec![0u8; len];
                if let Err(e) = conn.read_exact(&mut buf) {
                    last = format!("DoT 读取响应失败: {}", e);
                    continue;
                }
                let (ips, rcode, truncated) = parse_response(&buf, qtype, Some(id))?;
                return Ok(Answer {
                    ips,
                    elapsed_ms: start.elapsed().as_millis(),
                    server: server.to_string(),
                    rcode,
                    truncated,
                });
            }
            Err(e) => last = e,
        }
    }
    Err(last)
}

fn query_doh(host: &str, server: &str, qtype: u16, timeout: Duration) -> Result<Answer, String> {
    let url = if let Some(rest) = server
        .strip_prefix("doh://")
        .or_else(|| server.strip_prefix("DOH://"))
    {
        format!("https://{}", rest)
    } else {
        server.to_string()
    };
    let start = Instant::now();
    let id = (start.elapsed().as_nanos() as u16) ^ 0x7C7C;
    let pkt = build_query(host, qtype, id);
    let mut req = crate::http::Req::new("POST", &url);
    req.read_timeout = timeout;
    req.connect_timeout = timeout;
    req.max_redirects = 2;
    req.headers.push(("Content-Type".into(), "application/dns-message".into()));
    req.headers.push(("Accept".into(), "application/dns-message".into()));
    req.headers.push(("Accept-Encoding".into(), "identity".into()));
    req.body = Some(std::sync::Arc::new(pkt));
    let cache = crate::http::ResolveCache::new(Vec::new(), timeout);
    let resp = crate::http::send(&req, &cache)?;
    if resp.status != 200 {
        return Err(format!("DoH HTTP {}", resp.status));
    }
    let mut body = Vec::new();
    resp.reader
        .take(512 * 1024)
        .read_to_end(&mut body)
        .map_err(|e| format!("DoH 读取失败: {}", e))?;
    let (ips, rcode, truncated) = parse_response(&body, qtype, Some(id))?;
    Ok(Answer {
        ips,
        elapsed_ms: start.elapsed().as_millis(),
        server: server.to_string(),
        rcode,
        truncated,
    })
}

fn query_tcp(host: &str, server: &str, qtype: u16, timeout: Duration) -> Result<Answer, String> {
    let (ip, port) = parse_server(server)?;
    let start = Instant::now();
    let mut stream =
        TcpStream::connect_timeout(&SocketAddr::new(ip, port), timeout).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(timeout)).ok();
    stream.set_write_timeout(Some(timeout)).ok();
    let id = (start.elapsed().as_nanos() as u16) ^ 0x5A5A;
    let pkt = build_query(host, qtype, id);
    // RFC 1035：TCP DNS 报文前必须有 2 字节长度前缀。
    stream
        .write_all(&(pkt.len() as u16).to_be_bytes())
        .and_then(|_| stream.write_all(&pkt))
        .map_err(|e| e.to_string())?;
    let mut len_buf = [0u8; 2];
    stream
        .read_exact(&mut len_buf)
        .map_err(|e| format!("DNS TCP 读取长度失败: {}", e))?;
    let len = u16::from_be_bytes(len_buf) as usize;
    if !(12..=65535).contains(&len) {
        return Err(format!("DNS TCP 响应长度异常: {}", len));
    }
    let mut buf = vec![0u8; len];
    stream
        .read_exact(&mut buf)
        .map_err(|e| format!("DNS TCP 读取响应失败: {}", e))?;
    let (ips, rcode, truncated) = parse_response(&buf, qtype, Some(id))?;
    Ok(Answer {
        ips,
        elapsed_ms: start.elapsed().as_millis(),
        server: server.to_string(),
        rcode,
        truncated,
    })
}

pub fn query(host: &str, server: &str, qtype: u16, timeout: Duration) -> Result<Answer, String> {
    let spec = server.trim();
    let lower = spec.to_ascii_lowercase();
    if lower.starts_with("https://") || lower.starts_with("doh://") {
        return query_doh(host, spec, qtype, timeout);
    }
    if lower.starts_with("dot://") || lower.starts_with("tls://") {
        return query_dot(host, spec, qtype, timeout);
    }
    let (ip, port) = parse_server(server)?;
    let bind = if ip.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let sock = UdpSocket::bind(bind).map_err(|e| format!("DNS socket: {}", e))?;
    sock.set_read_timeout(Some(timeout)).ok();
    sock.set_write_timeout(Some(timeout)).ok();
    let start = Instant::now();
    let id = (start.elapsed().as_nanos() as u16) ^ 0x1234;
    let pkt = build_query(host, qtype, id);
    sock.send_to(&pkt, SocketAddr::new(ip, port))
        .map_err(|e| format!("DNS send: {}", e))?;
    let mut buf = vec![0u8; 2048];
    let deadline = start + timeout;
    let mut n = 0usize;
    for _ in 0..8 {
        let remain = deadline.saturating_duration_since(Instant::now());
        if remain.is_zero() {
            return Err("DNS recv 超时".into());
        }
        sock.set_read_timeout(Some(remain)).ok();
        let (got, from) = sock
            .recv_from(&mut buf)
            .map_err(|e| format!("DNS recv: {}", e))?;
        // 丢弃不是目标服务器、或 ID 不匹配的报文，避免接受伪造应答。
        if from.ip() != ip || from.port() != port {
            continue;
        }
        if got >= 2 && u16::from_be_bytes([buf[0], buf[1]]) != id {
            continue;
        }
        n = got;
        break;
    }
    if n == 0 {
        return Err("DNS 无有效响应".into());
    }
    let (ips, rcode, truncated) = parse_response(&buf[..n], qtype, Some(id))?;
    if truncated {
        return query_tcp(host, server, qtype, timeout);
    }
    Ok(Answer {
        ips,
        elapsed_ms: start.elapsed().as_millis(),
        server: server.to_string(),
        rcode,
        truncated,
    })
}

/// 同时查询全部配置的 DNS（UDP/DoT/DoH 可混合），返回每台服务器的有效结果。
/// 这是「设置里写几个 DNS 就用几个」的核心实现；慢服务器到总超时即放弃，不拖累快服务器。
pub fn query_all(host: &str, servers: &[String], qtype: u16, timeout: Duration) -> Vec<Answer> {
    let servers = dedupe_servers(servers);
    if let Ok(ip) = host.parse::<IpAddr>() {
        return vec![Answer {
            ips: vec![ip],
            elapsed_ms: 0,
            server: "ip".into(),
            rcode: 0,
            truncated: false,
        }];
    }
    if servers.is_empty() {
        return Vec::new();
    }
    let (tx, rx) = mpsc::channel();
    for (idx, server) in servers.iter().cloned().enumerate() {
        let tx = tx.clone();
        let host = host.to_string();
        thread::spawn(move || {
            let _ = tx.send((idx, query(&host, &server, qtype, timeout)));
        });
    }
    drop(tx);
    let total = servers.len();
    let mut slots: Vec<Option<Answer>> = (0..total).map(|_| None).collect();
    let deadline = Instant::now() + timeout + Duration::from_millis(300);
    let mut completed = 0usize;
    while completed < total {
        let remain = deadline.saturating_duration_since(Instant::now());
        if remain.is_zero() {
            break;
        }
        match rx.recv_timeout(remain.min(Duration::from_secs(2))) {
            Ok((idx, Ok(a))) => {
                completed += 1;
                slots[idx] = Some(a);
            }
            Ok((_idx, Err(_))) => {
                completed += 1;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    slots.into_iter().flatten().collect()
}

/// 依次尝试多个 DNS 服务器，返回第一个成功结果。
pub fn resolve_with_servers(
    host: &str,
    servers: &[String],
    qtype: u16,
    timeout: Duration,
    start_index: usize,
) -> Result<Answer, String> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(Answer {
            ips: vec![ip],
            elapsed_ms: 0,
            server: "ip".into(),
            rcode: 0,
            truncated: false,
        });
    }
    let servers = dedupe_servers(servers);
    if servers.is_empty() {
        return Err("未配置 DNS 服务器".into());
    }
    let _ = start_index;
    let answers = query_all(host, &servers, qtype, timeout);
    if answers.is_empty() {
        return Err(format!("{} 台 DNS 均未返回结果", servers.len()));
    }
    let mut ips = Vec::new();
    let mut servers_used = Vec::new();
    let mut max_ms = 0u128;
    let mut rcode = 0u16;
    for a in &answers {
        max_ms = max_ms.max(a.elapsed_ms);
        rcode = a.rcode;
        if !a.ips.is_empty() {
            servers_used.push(a.server.clone());
            for ip in &a.ips {
                if !ips.contains(ip) {
                    ips.push(*ip);
                }
            }
        }
    }
    if ips.is_empty() {
        return Err(format!("{} 台 DNS 均无匹配记录 (rcode={})", servers.len(), rcode));
    }
    Ok(Answer {
        ips,
        elapsed_ms: max_ms,
        server: servers_used.join(" / "),
        rcode,
        truncated: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dedupe_normalizes_aliases() {
        let servers = vec![
            " 8.8.8.8 ".to_string(),
            "8.8.8.8:53".to_string(),
            "tls://dns.google".to_string(),
            "dot://dns.google:853".to_string(),
            "https://dns.google/dns-query/".to_string(),
            "https://dns.google/dns-query".to_string(),
            "# comment".to_string(),
            String::new(),
        ];
        let out = dedupe_servers(&servers);
        assert_eq!(
            out,
            vec![
                "8.8.8.8",
                "tls://dns.google",
                "https://dns.google/dns-query/",
            ]
        );
    }
}
