//! 通用 HTTP 取数：给内置浏览器的站点解析器（FluxDown 兼容插件）用。
//!
//! 插件运行在 WebView 的 JS 沙箱里，`flux.fetch()` 通过 JS bridge 把请求转到这里。
//! 这里复用下载器的 HTTP 栈，保证自定义 DNS、代理、重定向与凭据剥离逻辑一致。

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Map, Value};

use crate::http::{send, Req, ResolveCache};

fn headers_from(v: &Value) -> Vec<(String, String)> {
    let mut out = Vec::new();
    match v {
        Value::Object(map) => {
            for (k, v) in map {
                let val = match v {
                    Value::String(s) => s.clone(),
                    Value::Null => continue,
                    other => other.to_string(),
                };
                if !k.trim().is_empty() && !val.is_empty() {
                    out.push((k.trim().to_string(), val));
                }
            }
        }
        Value::Array(list) => {
            for item in list {
                let k = item
                    .get("name")
                    .or_else(|| item.get(0))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let val = item
                    .get("value")
                    .or_else(|| item.get(1))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if !k.trim().is_empty() && !val.is_empty() {
                    out.push((k.trim().to_string(), val.to_string()));
                }
            }
        }
        _ => {}
    }
    out
}

fn header_map(headers: &[(String, String)], lower: bool) -> Value {
    let mut out = Map::new();
    for (k, v) in headers {
        let key = if lower {
            k.to_ascii_lowercase()
        } else {
            k.clone()
        };
        out.entry(key)
            .and_modify(|cur: &mut Value| {
                if let Some(s) = cur.as_str() {
                    *cur = Value::String(format!("{}, {}", s, v));
                }
            })
            .or_insert_with(|| Value::String(v.clone()));
    }
    Value::Object(out)
}

pub fn fetch(args: &Value) -> Result<Value, String> {
    let url = args["url"].as_str().ok_or("缺少 url")?.trim().to_string();
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("只支持 http/https 请求".into());
    }
    let method = args["method"]
        .as_str()
        .unwrap_or("GET")
        .trim()
        .to_ascii_uppercase();
    if !matches!(
        method.as_str(),
        "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD"
    ) {
        return Err(format!("不支持的请求方法: {}", method));
    }
    let mut req = Req::new(&method, &url);
    req.read_timeout = Duration::from_millis(
        args["timeoutMs"]
            .as_u64()
            .unwrap_or(30_000)
            .clamp(1_000, 120_000),
    );
    req.connect_timeout = Duration::from_millis(
        args["connectTimeoutMs"]
            .as_u64()
            .unwrap_or(10_000)
            .clamp(1_000, 30_000),
    );
    req.max_redirects = args["maxRedirects"].as_u64().unwrap_or(6).min(10) as u8;
    if let Some(ua) = args["userAgent"].as_str() {
        if !ua.is_empty() {
            req.user_agent = ua.to_string();
        }
    }
    req.headers
        .push(("Accept-Encoding".into(), "identity".into()));
    for (k, v) in headers_from(&args["headers"]) {
        // Host / Content-Length 交给 HTTP 栈自己算，避免和实际请求冲突。
        let lower = k.to_ascii_lowercase();
        if lower == "host" || lower == "content-length" || lower == "connection" {
            continue;
        }
        req.headers.push((k, v));
    }
    if method != "GET" && method != "HEAD" {
        let body = args["body"]
            .as_str()
            .map(|s| s.as_bytes().to_vec())
            .unwrap_or_default();
        req.body = Some(Arc::new(body));
    }
    let cache = ResolveCache::new(Vec::new(), Duration::from_secs(8));
    let mut resp = send(&req, &cache).map_err(|e| format!("请求失败: {}", e))?;
    let limit = args["maxBytes"]
        .as_u64()
        .unwrap_or(6 * 1024 * 1024)
        .clamp(1024, 32 * 1024 * 1024) as usize;
    let mut raw = Vec::new();
    resp.reader
        .by_ref()
        .take(limit as u64 + 1)
        .read_to_end(&mut raw)
        .map_err(|e| format!("读取响应失败: {}", e))?;
    let truncated = raw.len() > limit;
    if truncated {
        raw.truncate(limit);
    }
    let response_type = args["responseType"].as_str().unwrap_or("text");
    let body = if response_type.eq_ignore_ascii_case("base64") {
        crate::http::base64_encode(&raw)
    } else {
        String::from_utf8_lossy(&raw).to_string()
    };
    Ok(json!({
        "status": resp.status,
        "headers": header_map(&resp.headers, true),
        "body": body,
        "finalUrl": resp.final_url,
        "truncated": truncated,
        "bytes": raw.len(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Read, Write};
    use std::net::TcpListener;

    fn serve_once(response: &'static [u8]) -> (String, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
            let mut request = String::new();
            let mut content_length = 0usize;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line.is_empty() {
                    break;
                }
                let lower = line.to_ascii_lowercase();
                if let Some(v) = lower.strip_prefix("content-length:") {
                    content_length = v.trim().parse().unwrap_or(0);
                }
                request.push_str(&line);
                if line.trim().is_empty() {
                    break;
                }
            }
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).unwrap();
            request.push_str(&String::from_utf8_lossy(&body));
            let mut stream = reader.into_inner();
            stream.write_all(response).unwrap();
            request
        });
        (format!("http://{}/probe", addr), handle)
    }

    #[test]
    fn fetch_posts_body_and_reads_response() {
        let (url, server) = serve_once(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello",
        );
        let out = fetch(&json!({
            "url": url,
            "method": "POST",
            "headers": {"X-Test": "1", "Content-Type": "text/plain"},
            "body": "payload",
        }))
        .unwrap();
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /probe"), "{request}");
        assert!(request.contains("x-test: 1") || request.contains("X-Test: 1"));
        assert!(request.ends_with("payload"), "{request}");
        assert_eq!(out["status"], 200);
        assert_eq!(out["body"], "hello");
        assert_eq!(out["truncated"], false);
        assert_eq!(out["headers"]["content-type"], "text/plain");
    }

    #[test]
    fn fetch_can_return_base64_and_respect_limit() {
        let (url, _server) = serve_once(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\n\r\n\x00\x01\x02\x03",
        );
        let out = fetch(&json!({
            "url": url,
            "responseType": "base64",
        }))
        .unwrap();
        assert_eq!(out["body"], "AAECAw==");
        assert_eq!(out["status"], 200);
    }
}
