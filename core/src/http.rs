//! 轻量 HTTP/1.1 客户端（rustls + 自定义 DNS 绑定）。
//! 之所以不用 reqwest：Android 交叉编译依赖更少、可精确绑定「多 DNS → 指定 IP」，
//! 并且能直接按字节统计吞吐。

use crate::dns;
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::os::unix::io::FromRawFd;
use std::ffi::CString;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

pub trait RW: Read + Write + Send {}
impl<T: Read + Write + Send> RW for T {}

pub struct Conn(pub Box<dyn RW>);
impl Read for Conn {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.read(buf)
    }
}
impl Write for Conn {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

#[derive(Debug, Clone)]
pub struct ParsedUrl {
    pub scheme: String,
    pub host: String,
    pub port: u16,
    pub path: String,
}

pub fn parse_url(u: &str) -> Result<ParsedUrl, String> {
    let (scheme, rest) = u
        .split_once("://")
        .ok_or_else(|| format!("无效 URL: {}", u))?;
    let scheme = scheme.to_ascii_lowercase();
    let (authority, path) = match rest.find(|c| c == '/' || c == '?') {
        Some(i) => {
            let tail = &rest[i..];
            (&rest[..i], if tail.starts_with('?') { format!("/{}", tail) } else { tail.to_string() })
        }
        None => (rest, "/".to_string()),
    };
    if authority.is_empty() {
        return Err("URL 缺少主机".into());
    }
    let (host, port) = if authority.starts_with('[') {
        let end = authority
            .find(']')
            .ok_or_else(|| "IPv6 地址缺少 ]".to_string())?;
        let host = authority[1..end].to_string();
        let port = if authority[end + 1..].starts_with(':') {
            authority[end + 2..].parse::<u16>().unwrap_or(default_port(&scheme))
        } else {
            default_port(&scheme)
        };
        (host, port)
    } else if let Some(i) = authority.rfind(':') {
        (
            authority[..i].to_string(),
            authority[i + 1..]
                .parse::<u16>()
                .unwrap_or_else(|_| default_port(&scheme)),
        )
    } else {
        (authority.to_string(), default_port(&scheme))
    };
    Ok(ParsedUrl {
        scheme,
        host,
        port,
        path: path.to_string(),
    })
}

fn default_port(scheme: &str) -> u16 {
    if scheme == "https" {
        443
    } else {
        80
    }
}

pub struct CacheEntry {
    pub ips: Vec<IpAddr>,
    pub at: Instant,
    pub server: String,
    pub ms: u128,
}

pub struct ResolveCache {
    pub servers: Vec<String>,
    pub timeout: Duration,
    /// all = 所有 DNS 并发；primary = 主 DNS 优先
    pub dns_mode: String,
    /// auto = 双栈；v4 = 仅 IPv4；v6 = 仅 IPv6
    pub ip_mode: String,
    map: Mutex<HashMap<String, CacheEntry>>,
}

impl ResolveCache {
    pub fn new(servers: Vec<String>, timeout: Duration) -> Self {
        Self {
            servers,
            timeout,
            dns_mode: "all".into(),
            ip_mode: "auto".into(),
            map: Mutex::new(HashMap::new()),
        }
    }

    pub fn with_modes(mut self, dns_mode: &str, ip_mode: &str) -> Self {
        self.dns_mode = normalize_dns_mode(dns_mode);
        self.ip_mode = normalize_ip_mode(ip_mode);
        self
    }

    pub fn resolve(&self, host: &str) -> Result<(Vec<IpAddr>, String, u128), String> {
        if let Ok(ip) = host.parse::<IpAddr>() {
            if self.ip_mode == "v4" && !ip.is_ipv4() {
                return Err("当前连接方式仅允许 IPv4".into());
            }
            if self.ip_mode == "v6" && !ip.is_ipv6() {
                return Err("当前连接方式仅允许 IPv6".into());
            }
            return Ok((vec![ip], "ip".to_string(), 0));
        }
        if let Some(e) = self.map.lock().unwrap().get(host) {
            if e.at.elapsed().as_secs() < 300 {
                return Ok((e.ips.clone(), e.server.clone(), e.ms));
            }
        }
        let mut last = String::from("DNS 解析失败");
        let qtypes: Vec<u16> = match self.ip_mode.as_str() {
            "v4" => vec![1],
            "v6" => vec![28],
            _ => vec![1, 28],
        };
        let mut answers = Vec::new();
        if !self.servers.is_empty() {
            for qtype in qtypes {
                if self.dns_mode == "primary" {
                    for server in &self.servers {
                        match dns::query(host, server, qtype, self.timeout) {
                            Ok(a) => {
                                answers.push(a);
                                break;
                            }
                            Err(e) => last = e,
                        }
                    }
                } else {
                    answers.extend(dns::query_all(host, &self.servers, qtype, self.timeout));
                }
            }
        }
        let mut ips: Vec<IpAddr> = Vec::new();
        let mut servers_used: Vec<String> = Vec::new();
        let mut max_ms = 0u128;
        for a in answers {
            max_ms = max_ms.max(a.elapsed_ms);
            if a.ips.is_empty() {
                last = format!("{} 无匹配记录", a.server);
                continue;
            }
            if !servers_used.contains(&a.server) {
                servers_used.push(a.server.clone());
            }
            for ip in a.ips {
                if !ips.contains(&ip) {
                    ips.push(ip);
                }
            }
        }
        ips.retain(|ip| match self.ip_mode.as_str() {
            "v4" => ip.is_ipv4(),
            "v6" => ip.is_ipv6(),
            _ => true,
        });
        if !ips.is_empty() {
            // auto 模式把 IPv4 放前面，缩短单栈网络的握手等待。
            if self.ip_mode == "auto" {
                ips.sort_by_key(|ip| if ip.is_ipv4() { 0 } else { 1 });
            }
            let server = servers_used.join(" / ");
            self.map.lock().unwrap().insert(
                host.to_string(),
                CacheEntry { ips: ips.clone(), at: Instant::now(), server: server.clone(), ms: max_ms },
            );
            return Ok((ips, server, max_ms));
        }
        if !servers_used.is_empty() {
            last = format!("{} 无匹配记录", servers_used.join(" / "));
        }
        // 自定义 DNS 不可用或没有匹配记录时，回退系统解析（仍遵守连接方式）。
        if let Ok(addrs) = (host, 443u16).to_socket_addrs() {
            let mut ips: Vec<IpAddr> = addrs.map(|a| a.ip()).collect();
            ips.retain(|ip| match self.ip_mode.as_str() {
                "v4" => ip.is_ipv4(),
                "v6" => ip.is_ipv6(),
                _ => true,
            });
            if !ips.is_empty() {
                self.map.lock().unwrap().insert(
                    host.to_string(),
                    CacheEntry { ips: ips.clone(), at: Instant::now(), server: "system".into(), ms: 0 },
                );
                return Ok((ips, "system".into(), 0));
            }
        }
        Err(format!("{}（{}）", last, host))
    }
}

fn normalize_dns_mode(v: &str) -> String {
    match v.trim().to_ascii_lowercase().as_str() {
        "primary" | "first" | "main" => "primary".into(),
        _ => "all".into(),
    }
}

fn normalize_ip_mode(v: &str) -> String {
    match v.trim().to_ascii_lowercase().as_str() {
        "v4" | "ipv4" | "仅ipv4" | "4" => "v4".into(),
        "v6" | "ipv6" | "仅ipv6" | "6" => "v6".into(),
        _ => "auto".into(),
    }
}

/// 把“源 IP 或网卡名”拆成 bind_ip / bind_if，留空表示自动。
pub fn parse_bind(spec: &str) -> (Option<IpAddr>, String) {
    let s = spec.trim();
    if s.is_empty() {
        return (None, String::new());
    }
    match s.parse::<IpAddr>() {
        Ok(ip) => (Some(ip), String::new()),
        Err(_) => (None, s.to_string()),
    }
}

#[derive(Clone)]
pub struct Req {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub read_timeout: Duration,
    pub connect_timeout: Duration,
    pub max_redirects: u8,
    pub user_agent: String,
    pub pin_ip: Option<std::net::IpAddr>,
    pub pin_dns: Option<String>,
    pub bind_ip: Option<std::net::IpAddr>,
    pub bind_if: String,
    /// 请求体实际写出的字节回调，用于上传测速的实时速率采样。
    pub write_progress: Option<std::sync::Arc<dyn Fn(usize) + Send + Sync>>,
}

impl Req {
    pub fn new(method: &str, url: &str) -> Self {
        Self {
            method: method.to_string(),
            url: url.to_string(),
            headers: Vec::new(),
            body: None,
            read_timeout: Duration::from_secs(15),
            connect_timeout: Duration::from_secs(8),
            max_redirects: 5,
            user_agent: "NetPulse/1.0".to_string(),
            pin_ip: None,
            pin_dns: None,
            bind_ip: None,
            bind_if: String::new(),
            write_progress: None,
        }
    }

    pub fn header(mut self, k: &str, v: &str) -> Self {
        self.headers.push((k.to_string(), v.to_string()));
        self
    }

    pub fn body(mut self, b: Vec<u8>) -> Self {
        self.body = Some(b);
        self
    }
}

pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub reader: Box<dyn Read + Send>,
    pub ip: String,
    pub dns_ms: u128,
    pub dns_server: String,
    pub final_url: String,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        let n = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(&n))
            .map(|(_, v)| v.as_str())
    }
}

/// 建立 TCP 连接，可在连接前绑定源 IP 或网卡（Android 多网络/多网卡）。
pub fn connect_tcp(
    addr: SocketAddr,
    timeout: Duration,
    bind_ip: Option<IpAddr>,
    bind_if: &str,
) -> Result<TcpStream, String> {
    unsafe {
        let domain = if addr.is_ipv4() { libc::AF_INET } else { libc::AF_INET6 };
        let fd = libc::socket(domain, libc::SOCK_STREAM, 0);
        if fd < 0 {
            return Err(format!("创建 socket 失败: {}", std::io::Error::last_os_error()));
        }
        let close = |fd: libc::c_int| { libc::close(fd); };
        if !bind_if.trim().is_empty() {
            let name = match CString::new(bind_if.trim().as_bytes()) {
                Ok(v) => v,
                Err(_) => { close(fd); return Err("网卡名无效".into()); }
            };
            let rc = libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_BINDTODEVICE,
                name.as_ptr() as *const libc::c_void,
                name.as_bytes().len() as libc::socklen_t,
            );
            if rc < 0 {
                let err = std::io::Error::last_os_error();
                close(fd);
                return Err(format!("绑定网卡 {} 失败: {}（通常需要 root 或系统权限）", bind_if, err));
            }
        }
        if let Some(ip) = bind_ip {
            if ip.is_ipv4() != addr.is_ipv4() {
                close(fd);
                return Err("源 IP 与目标地址协议族不一致".into());
            }
            let rc = match ip {
                IpAddr::V4(v4) => {
                    let mut sa: libc::sockaddr_in = std::mem::zeroed();
                    sa.sin_family = libc::AF_INET as libc::sa_family_t;
                    sa.sin_port = 0;
                    sa.sin_addr.s_addr = u32::from_ne_bytes(v4.octets());
                    libc::bind(fd, &sa as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t)
                }
                IpAddr::V6(v6) => {
                    let mut sa: libc::sockaddr_in6 = std::mem::zeroed();
                    sa.sin6_family = libc::AF_INET6 as libc::sa_family_t;
                    sa.sin6_port = 0;
                    sa.sin6_addr.s6_addr = v6.octets();
                    libc::bind(fd, &sa as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t)
                }
            };
            if rc < 0 {
                let err = std::io::Error::last_os_error();
                close(fd);
                return Err(format!("绑定源 IP {} 失败: {}", ip, err));
            }
        }
        let flags = libc::fcntl(fd, libc::F_GETFL, 0);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        let rc = match addr {
            SocketAddr::V4(v4) => {
                let mut sa: libc::sockaddr_in = std::mem::zeroed();
                sa.sin_family = libc::AF_INET as libc::sa_family_t;
                sa.sin_port = v4.port().to_be();
                sa.sin_addr.s_addr = u32::from_ne_bytes(v4.ip().octets());
                libc::connect(
                    fd,
                    &sa as *const _ as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
                )
            }
            SocketAddr::V6(v6) => {
                let mut sa: libc::sockaddr_in6 = std::mem::zeroed();
                sa.sin6_family = libc::AF_INET6 as libc::sa_family_t;
                sa.sin6_port = v6.port().to_be();
                sa.sin6_addr.s6_addr = v6.ip().octets();
                libc::connect(
                    fd,
                    &sa as *const _ as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
                )
            }
        };
        if rc < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EINPROGRESS) {
            let err = std::io::Error::last_os_error();
            close(fd);
            return Err(format!("连接 {} 失败: {}", addr, err));
        }
        if rc < 0 {
            let mut pfd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            let ms = timeout.as_millis().min(i32::MAX as u128) as i32;
            let ready = libc::poll(&mut pfd, 1, ms);
            if ready <= 0 {
                close(fd);
                return Err(format!("连接 {} 超时", addr));
            }
            let mut err: libc::c_int = 0;
            let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
            libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_ERROR, &mut err as *mut _ as *mut libc::c_void, &mut len);
            if err != 0 {
                close(fd);
                return Err(format!("连接 {} 失败: {}", addr, std::io::Error::from_raw_os_error(err)));
            }
        }
        libc::fcntl(fd, libc::F_SETFL, flags);
        Ok(TcpStream::from_raw_fd(fd))
    }
}

pub(crate) fn tls_config() -> Arc<rustls::ClientConfig> {
    static CFG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CFG.get_or_init(|| {
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(roots)
        .with_no_client_auth();
        Arc::new(cfg)
    })
    .clone()
}

/// 建立 TLS 连接，用于 DNS over TLS 等非 HTTP 场景。
pub fn tls_connect(host: &str, ip: IpAddr, port: u16, timeout: Duration) -> Result<Conn, String> {
    let addr = SocketAddr::new(ip, port);
    let tcp = connect_tcp(addr, timeout, None, "")
        .map_err(|e| format!("TLS 连接 {}: {}", addr, e))?;
    tcp.set_nodelay(true).ok();
    tcp.set_read_timeout(Some(timeout)).ok();
    tcp.set_write_timeout(Some(timeout)).ok();
    let cfg = tls_config();
    let server_name = match host.parse::<IpAddr>() {
        Ok(ip) => rustls::pki_types::ServerName::IpAddress(ip.into()),
        Err(_) => rustls::pki_types::ServerName::try_from(host.to_string())
            .map_err(|_| format!("TLS 主机名无效: {}", host))?,
    };
    let tls = rustls::ClientConnection::new(cfg, server_name)
        .map_err(|e| format!("TLS 初始化失败: {}", e))?;
    Ok(Conn(Box::new(rustls::StreamOwned::new(tls, tcp)) as Box<dyn RW>))
}

fn read_line(r: &mut dyn Read) -> io::Result<String> {
    let mut s = Vec::new();
    let mut b = [0u8; 1];
    loop {
        r.read_exact(&mut b)?;
        if b[0] == b'\n' {
            break;
        }
        if b[0] != b'\r' {
            s.push(b[0]);
        }
        if s.len() > 4096 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "行过长"));
        }
    }
    Ok(String::from_utf8_lossy(&s).to_string())
}

pub struct ChunkedReader<R: Read> {
    inner: R,
    remaining: usize,
    done: bool,
}

impl<R: Read> ChunkedReader<R> {
    pub fn new(inner: R) -> Self {
        Self {
            inner,
            remaining: 0,
            done: false,
        }
    }
}

impl<R: Read> Read for ChunkedReader<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.done {
            return Ok(0);
        }
        if self.remaining == 0 {
            let line = read_line(&mut self.inner)?;
            let size_str = line.split(';').next().unwrap_or("").trim();
            let n = usize::from_str_radix(size_str, 16).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, format!("chunk 头无效: {}", line))
            })?;
            if n == 0 {
                self.done = true;
                // 吃掉 trailer 直到空行
                loop {
                    let l = read_line(&mut self.inner)?;
                    if l.is_empty() {
                        break;
                    }
                }
                return Ok(0);
            }
            self.remaining = n;
        }
        let want = out.len().min(self.remaining);
        let n = self.inner.read(&mut out[..want])?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "chunk 截断"));
        }
        self.remaining -= n;
        if self.remaining == 0 {
            let _ = read_line(&mut self.inner)?;
        }
        Ok(n)
    }
}

fn absolutize(base: &ParsedUrl, location: &str) -> String {
    if location.starts_with("http://") || location.starts_with("https://") {
        return location.to_string();
    }
    if location.starts_with("//") {
        return format!("{}:{}", base.scheme, location);
    }
    if location.starts_with('/') {
        let port = if (base.scheme == "https" && base.port == 443)
            || (base.scheme == "http" && base.port == 80)
        {
            String::new()
        } else {
            format!(":{}", base.port)
        };
        return format!(
            "{}://{}{}{}",
            base.scheme, base.host, port, location
        );
    }
    let dir = match base.path.rfind('/') {
        Some(i) => &base.path[..=i],
        None => "/",
    };
    let port = if (base.scheme == "https" && base.port == 443)
        || (base.scheme == "http" && base.port == 80)
    {
        String::new()
    } else {
        format!(":{}", base.port)
    };
    format!("{}://{}{}{}{}", base.scheme, base.host, port, dir, location)
}

pub fn send(req: &Req, cache: &ResolveCache) -> Result<Response, String> {
    let mut url = req.url.clone();
    let mut method = req.method.clone();
    let mut body = req.body.clone();
    let mut left = req.max_redirects;
    loop {
        let parsed = parse_url(&url)?;
        let resp = send_once(&parsed, &method, req, body.as_deref(), cache)?;
        if resp.status >= 300 && resp.status < 400 && left > 0 {
            if let Some(loc) = resp.header("location").map(|s| s.to_string()) {
                let status = resp.status;
                drop(resp);
                url = absolutize(&parsed, &loc);
                if status == 303 {
                    method = "GET".to_string();
                    body = None;
                }
                left -= 1;
                continue;
            }
        }
        let mut resp = resp;
        resp.final_url = url.clone();
        return Ok(resp);
    }
}

fn send_once(
    parsed: &ParsedUrl,
    method: &str,
    req: &Req,
    body: Option<&[u8]>,
    cache: &ResolveCache,
) -> Result<Response, String> {
    let (ips, dns_server, dns_ms) = match req.pin_ip {
        Some(ip) => (vec![ip], req.pin_dns.clone().unwrap_or_else(|| "pin".into()), 0u128),
        None => cache.resolve(&parsed.host)?,
    };
    let mut last_err = String::from("连接失败");
    let mut tcp: Option<TcpStream> = None;
    let mut used_ip = String::new();
    for ip in ips {
        let addr = SocketAddr::new(ip, parsed.port);
        match connect_tcp(addr, req.connect_timeout, req.bind_ip, req.bind_if.as_str()) {
            Ok(s) => {
                used_ip = ip.to_string();
                tcp = Some(s);
                break;
            }
            Err(e) => last_err = format!("{}: {}", ip, e),
        }
    }
    let tcp = tcp.ok_or(last_err)?;
    tcp.set_nodelay(true).ok();
    tcp.set_read_timeout(Some(req.read_timeout)).ok();
    tcp.set_write_timeout(Some(req.read_timeout)).ok();

    let mut conn = Conn(if parsed.scheme == "https" {
        let cfg = tls_config();
        let server_name = match parsed.host.parse::<IpAddr>() {
            Ok(ip) => rustls::pki_types::ServerName::IpAddress(ip.into()),
            Err(_) => rustls::pki_types::ServerName::try_from(parsed.host.clone())
                .map_err(|_| format!("TLS 主机名无效: {}", parsed.host))?,
        };
        let tls = rustls::ClientConnection::new(cfg, server_name)
            .map_err(|e| format!("TLS 初始化失败: {}", e))?;
        Box::new(rustls::StreamOwned::new(tls, tcp)) as Box<dyn RW>
    } else {
        Box::new(tcp) as Box<dyn RW>
    });

    // 组装请求
    let host_header = if parsed.port == default_port(&parsed.scheme) {
        parsed.host.clone()
    } else if parsed.host.contains(':') {
        format!("[{}]:{}", parsed.host, parsed.port)
    } else {
        format!("{}:{}", parsed.host, parsed.port)
    };
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {}\r\nAccept: */*\r\nConnection: close\r\n",
        method, parsed.path, host_header, req.user_agent
    );
    for (k, v) in &req.headers {
        head.push_str(&format!("{}: {}\r\n", k, v));
    }
    if let Some(b) = body {
        if !req
            .headers
            .iter()
            .any(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        {
            head.push_str(&format!("Content-Length: {}\r\n", b.len()));
        }
    }
    head.push_str("\r\n");
    conn.write_all(head.as_bytes())
        .map_err(|e| format!("发送请求失败: {}", e))?;
    if let Some(b) = body {
        for chunk in b.chunks(64 * 1024) {
            conn.write_all(chunk).map_err(|e| format!("发送请求体失败: {}", e))?;
            if let Some(cb) = &req.write_progress {
                cb(chunk.len());
            }
        }
    }
    conn.flush().map_err(|e| format!("flush 失败: {}", e))?;

    // 读状态行
    let status_line = read_line(&mut conn).map_err(|e| format!("读取响应失败: {}", e))?;
    let mut parts = status_line.split_whitespace();
    let _http = parts.next().unwrap_or("");
    let status: u16 = parts
        .next()
        .unwrap_or("0")
        .parse()
        .map_err(|_| format!("状态码无效: {}", status_line))?;

    let mut headers = Vec::new();
    loop {
        let line = read_line(&mut conn).map_err(|e| format!("读取响应头失败: {}", e))?;
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }

    let chunked = headers.iter().any(|(k, v)| {
        k.eq_ignore_ascii_case("transfer-encoding") && v.to_ascii_lowercase().contains("chunked")
    });
    let length = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse::<usize>().ok());

    let reader: Box<dyn Read + Send> = if chunked && method != "HEAD" {
        Box::new(ChunkedReader::new(conn))
    } else if let Some(n) = length {
        Box::new(conn.take(n as u64))
    } else {
        Box::new(conn)
    };

    Ok(Response {
        status,
        headers,
        reader,
        ip: used_ip,
        dns_ms,
        dns_server,
        final_url: String::new(),
    })
}

