//! IP 归属地：内置可更新位置库 + 可配置 IP API。
//!
//! 本地库采用紧凑 TSV（start\tend\tcountry\tregion\tcity\tisp），支持 CSV / CSV.GZ 导入；
//! 无本地文件时使用编译进二进制的国家/地区级种子库。

use crate::http::{send, Req, ResolveCache};
use serde_json::{json, Value};
use std::fs;
use std::io::Read;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::thread;

#[derive(Clone)]
struct Entry {
    start: u32,
    end: u32,
    country: String,
    region: String,
    city: String,
    isp: String,
}

struct Cache {
    key: String,
    entries: Vec<Entry>,
}

static CACHE: OnceLock<Mutex<Option<Cache>>> = OnceLock::new();
static SEED: OnceLock<Vec<Entry>> = OnceLock::new();

fn ipv4(s: &str) -> Option<u32> {
    let parts: Vec<&str> = s.trim().split('.').collect();
    if parts.len() != 4 {
        return None;
    }
    let mut v: u32 = 0;
    for p in parts {
        let n: u32 = p.parse().ok()?;
        if n > 255 {
            return None;
        }
        v = (v << 8) | n;
    }
    Some(v)
}

fn u32ip(v: u32) -> String {
    format!("{}.{}.{}.{}", v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255)
}

fn split_csv(line: &str, delim: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '"' {
            if quoted && chars.peek() == Some(&'"') {
                cur.push('"');
                chars.next();
            } else {
                quoted = !quoted;
            }
        } else if c == delim && !quoted {
            out.push(cur.trim().to_string());
            cur.clear();
        } else if c != '\r' && c != '\n' {
            cur.push(c);
        }
    }
    out.push(cur.trim().to_string());
    out
}

fn parse_db(text: &str) -> Vec<Entry> {
    let mut entries: Vec<Entry> = Vec::new();
    let mut cols: Option<(usize, usize, usize, usize, usize, usize)> = None;
    for (i, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let delim = if line.contains('\t') { '\t' } else { ',' };
        let f = split_csv(line, delim);
        if f.len() < 2 {
            continue;
        }
        let is_header = ipv4(&f[0]).is_none() && f[0].parse::<u32>().is_err();
        if is_header {
            let get = |keys: &[&str]| {
                f.iter().position(|h| {
                    let h = h.to_ascii_lowercase();
                    keys.iter().any(|k| h == *k || h.contains(*k))
                })
            };
            let start = get(&["ip_range_start", "range_start", "start"]).unwrap_or(0);
            let end = get(&["ip_range_end", "range_end", "end"]).unwrap_or(1);
            let country = get(&["country_name", "country_code", "country"]).unwrap_or(2.min(f.len() - 1));
            let region = get(&["region_name", "region"]).unwrap_or(3.min(f.len() - 1));
            let city = get(&["city_name", "city"]).unwrap_or(4.min(f.len() - 1));
            let isp = get(&["isp", "organization", "org"]).unwrap_or(5.min(f.len() - 1));
            cols = Some((start, end, country, region, city, isp));
            continue;
        }
        let (si, ei, ci, ri, mi, ii) = cols.unwrap_or((0, 1, 2, 3, 4, 5));
        if f.len() <= si.max(ei) {
            continue;
        }
        let start = ipv4(&f[si]).or_else(|| f[si].parse::<u32>().ok());
        let end = ipv4(&f[ei]).or_else(|| f[ei].parse::<u32>().ok());
        if let (Some(s), Some(e)) = (start, end) {
            if e >= s {
                let take = |idx: usize| if idx < f.len() { f[idx].clone() } else { String::new() };
                entries.push(Entry {
                    start: s,
                    end: e,
                    country: take(ci),
                    region: take(ri),
                    city: take(mi),
                    isp: take(ii),
                });
            }
        }
        if i > 0 && entries.len() > 900_000 {
            break;
        }
    }
    entries.sort_by_key(|e| e.start);
    entries
}

fn seed_entries() -> &'static Vec<Entry> {
    SEED.get_or_init(|| {
        let gz = include_bytes!("../assets/ipdb_seed.tsv.gz");
        let mut dec = flate2::read::GzDecoder::new(&gz[..]);
        let mut text = String::new();
        let _ = dec.read_to_string(&mut text);
        parse_db(&text)
    })
}

fn cache_key(path: &str) -> String {
    match fs::metadata(path) {
        Ok(m) => {
            let modified = m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
            format!("{}:{}:{}", path, modified, m.len())
        }
        Err(_) => format!("{}:seed", path),
    }
}

fn load(path: &str) -> Vec<Entry> {
    let key = cache_key(path);
    let lock = CACHE.get_or_init(|| Mutex::new(None));
    let mut guard = lock.lock().unwrap();
    if let Some(c) = guard.as_ref() {
        if c.key == key {
            return c.entries.clone();
        }
    }
    let entries = if Path::new(path).exists() {
        fs::read_to_string(path).map(|t| parse_db(&t)).unwrap_or_default()
    } else {
        seed_entries().clone()
    };
    *guard = Some(Cache { key, entries: entries.clone() });
    entries
}

fn find(entries: &[Entry], ip: u32) -> Option<Entry> {
    let mut hi = entries.partition_point(|e| e.start <= ip);
    while hi > 0 {
        hi -= 1;
        let e = &entries[hi];
        if e.start <= ip && ip <= e.end {
            return Some(e.clone());
        }
        if entries.len() - hi > 8 {
            break;
        }
    }
    None
}

fn country_name(code: &str) -> String {
    match code.to_ascii_uppercase().as_str() {
        "AD" => "Andorra",
        "AE" => "United Arab Emirates",
        "AF" => "Afghanistan",
        "AG" => "Antigua and Barbuda",
        "AI" => "Anguilla",
        "AL" => "Albania",
        "AM" => "Armenia",
        "AO" => "Angola",
        "AQ" => "Antarctica",
        "AR" => "Argentina",
        "AS" => "American Samoa",
        "AT" => "Austria",
        "AU" => "Australia",
        "AW" => "Aruba",
        "AX" => "Åland Islands",
        "AZ" => "Azerbaijan",
        "BA" => "Bosnia and Herzegovina",
        "BB" => "Barbados",
        "BD" => "Bangladesh",
        "BE" => "Belgium",
        "BF" => "Burkina Faso",
        "BG" => "Bulgaria",
        "BH" => "Bahrain",
        "BI" => "Burundi",
        "BJ" => "Benin",
        "BL" => "Saint Barthélemy",
        "BM" => "Bermuda",
        "BN" => "Brunei Darussalam",
        "BO" => "Bolivia, Plurinational State of",
        "BQ" => "Bonaire, Sint Eustatius and Saba",
        "BR" => "Brazil",
        "BS" => "Bahamas",
        "BT" => "Bhutan",
        "BV" => "Bouvet Island",
        "BW" => "Botswana",
        "BY" => "Belarus",
        "BZ" => "Belize",
        "CA" => "Canada",
        "CC" => "Cocos (Keeling) Islands",
        "CD" => "Congo, The Democratic Republic of the",
        "CF" => "Central African Republic",
        "CG" => "Congo",
        "CH" => "Switzerland",
        "CI" => "Côte d'Ivoire",
        "CK" => "Cook Islands",
        "CL" => "Chile",
        "CM" => "Cameroon",
        "CN" => "China",
        "CO" => "Colombia",
        "CR" => "Costa Rica",
        "CU" => "Cuba",
        "CV" => "Cabo Verde",
        "CW" => "Curaçao",
        "CX" => "Christmas Island",
        "CY" => "Cyprus",
        "CZ" => "Czechia",
        "DE" => "Germany",
        "DJ" => "Djibouti",
        "DK" => "Denmark",
        "DM" => "Dominica",
        "DO" => "Dominican Republic",
        "DZ" => "Algeria",
        "EC" => "Ecuador",
        "EE" => "Estonia",
        "EG" => "Egypt",
        "EH" => "Western Sahara",
        "ER" => "Eritrea",
        "ES" => "Spain",
        "ET" => "Ethiopia",
        "FI" => "Finland",
        "FJ" => "Fiji",
        "FK" => "Falkland Islands (Malvinas)",
        "FM" => "Micronesia, Federated States of",
        "FO" => "Faroe Islands",
        "FR" => "France",
        "GA" => "Gabon",
        "GB" => "United Kingdom",
        "GD" => "Grenada",
        "GE" => "Georgia",
        "GF" => "French Guiana",
        "GG" => "Guernsey",
        "GH" => "Ghana",
        "GI" => "Gibraltar",
        "GL" => "Greenland",
        "GM" => "Gambia",
        "GN" => "Guinea",
        "GP" => "Guadeloupe",
        "GQ" => "Equatorial Guinea",
        "GR" => "Greece",
        "GS" => "South Georgia and the South Sandwich Islands",
        "GT" => "Guatemala",
        "GU" => "Guam",
        "GW" => "Guinea-Bissau",
        "GY" => "Guyana",
        "HK" => "Hong Kong",
        "HM" => "Heard Island and McDonald Islands",
        "HN" => "Honduras",
        "HR" => "Croatia",
        "HT" => "Haiti",
        "HU" => "Hungary",
        "ID" => "Indonesia",
        "IE" => "Ireland",
        "IL" => "Israel",
        "IM" => "Isle of Man",
        "IN" => "India",
        "IO" => "British Indian Ocean Territory",
        "IQ" => "Iraq",
        "IR" => "Iran, Islamic Republic of",
        "IS" => "Iceland",
        "IT" => "Italy",
        "JE" => "Jersey",
        "JM" => "Jamaica",
        "JO" => "Jordan",
        "JP" => "Japan",
        "KE" => "Kenya",
        "KG" => "Kyrgyzstan",
        "KH" => "Cambodia",
        "KI" => "Kiribati",
        "KM" => "Comoros",
        "KN" => "Saint Kitts and Nevis",
        "KP" => "Korea, Democratic People's Republic of",
        "KR" => "Korea, Republic of",
        "KW" => "Kuwait",
        "KY" => "Cayman Islands",
        "KZ" => "Kazakhstan",
        "LA" => "Lao People's Democratic Republic",
        "LB" => "Lebanon",
        "LC" => "Saint Lucia",
        "LI" => "Liechtenstein",
        "LK" => "Sri Lanka",
        "LR" => "Liberia",
        "LS" => "Lesotho",
        "LT" => "Lithuania",
        "LU" => "Luxembourg",
        "LV" => "Latvia",
        "LY" => "Libya",
        "MA" => "Morocco",
        "MC" => "Monaco",
        "MD" => "Moldova, Republic of",
        "ME" => "Montenegro",
        "MF" => "Saint Martin (French part)",
        "MG" => "Madagascar",
        "MH" => "Marshall Islands",
        "MK" => "North Macedonia",
        "ML" => "Mali",
        "MM" => "Myanmar",
        "MN" => "Mongolia",
        "MO" => "Macao",
        "MP" => "Northern Mariana Islands",
        "MQ" => "Martinique",
        "MR" => "Mauritania",
        "MS" => "Montserrat",
        "MT" => "Malta",
        "MU" => "Mauritius",
        "MV" => "Maldives",
        "MW" => "Malawi",
        "MX" => "Mexico",
        "MY" => "Malaysia",
        "MZ" => "Mozambique",
        "NA" => "Namibia",
        "NC" => "New Caledonia",
        "NE" => "Niger",
        "NF" => "Norfolk Island",
        "NG" => "Nigeria",
        "NI" => "Nicaragua",
        "NL" => "Netherlands",
        "NO" => "Norway",
        "NP" => "Nepal",
        "NR" => "Nauru",
        "NU" => "Niue",
        "NZ" => "New Zealand",
        "OM" => "Oman",
        "PA" => "Panama",
        "PE" => "Peru",
        "PF" => "French Polynesia",
        "PG" => "Papua New Guinea",
        "PH" => "Philippines",
        "PK" => "Pakistan",
        "PL" => "Poland",
        "PM" => "Saint Pierre and Miquelon",
        "PN" => "Pitcairn",
        "PR" => "Puerto Rico",
        "PS" => "Palestine, State of",
        "PT" => "Portugal",
        "PW" => "Palau",
        "PY" => "Paraguay",
        "QA" => "Qatar",
        "RE" => "Réunion",
        "RO" => "Romania",
        "RS" => "Serbia",
        "RU" => "Russian Federation",
        "RW" => "Rwanda",
        "SA" => "Saudi Arabia",
        "SB" => "Solomon Islands",
        "SC" => "Seychelles",
        "SD" => "Sudan",
        "SE" => "Sweden",
        "SG" => "Singapore",
        "SH" => "Saint Helena, Ascension and Tristan da Cunha",
        "SI" => "Slovenia",
        "SJ" => "Svalbard and Jan Mayen",
        "SK" => "Slovakia",
        "SL" => "Sierra Leone",
        "SM" => "San Marino",
        "SN" => "Senegal",
        "SO" => "Somalia",
        "SR" => "Suriname",
        "SS" => "South Sudan",
        "ST" => "Sao Tome and Principe",
        "SV" => "El Salvador",
        "SX" => "Sint Maarten (Dutch part)",
        "SY" => "Syrian Arab Republic",
        "SZ" => "Eswatini",
        "TC" => "Turks and Caicos Islands",
        "TD" => "Chad",
        "TF" => "French Southern Territories",
        "TG" => "Togo",
        "TH" => "Thailand",
        "TJ" => "Tajikistan",
        "TK" => "Tokelau",
        "TL" => "Timor-Leste",
        "TM" => "Turkmenistan",
        "TN" => "Tunisia",
        "TO" => "Tonga",
        "TR" => "Turkey",
        "TT" => "Trinidad and Tobago",
        "TV" => "Tuvalu",
        "TW" => "Taiwan, Province of China",
        "TZ" => "Tanzania, United Republic of",
        "UA" => "Ukraine",
        "UG" => "Uganda",
        "UM" => "United States Minor Outlying Islands",
        "US" => "United States",
        "UY" => "Uruguay",
        "UZ" => "Uzbekistan",
        "VA" => "Holy See (Vatican City State)",
        "VC" => "Saint Vincent and the Grenadines",
        "VE" => "Venezuela, Bolivarian Republic of",
        "VG" => "Virgin Islands, British",
        "VI" => "Virgin Islands, U.S.",
        "VN" => "Viet Nam",
        "VU" => "Vanuatu",
        "WF" => "Wallis and Futuna",
        "WS" => "Samoa",
        "YE" => "Yemen",
        "YT" => "Mayotte",
        "ZA" => "South Africa",
        "ZM" => "Zambia",
        "ZW" => "Zimbabwe",
        _ => return code.to_string(),
    }
    .to_string()
}

fn http_cache() -> ResolveCache {
    // 走系统解析器，自动适配当前网络与 IPv4/IPv6；避免公共 DNS 被污染时 API 全部失败。
    ResolveCache::new(Vec::new(), Duration::from_secs(4))
}

fn extract_ip(body: &str, v6: bool) -> Option<String> {
    let mut token = String::new();
    for ch in body.chars() {
        if ch.is_ascii_hexdigit() || ch == '.' || ch == ':' || ch == 'x' || ch == 'X' {
            token.push(ch);
        } else {
            if !token.is_empty() {
                let t = token.trim_matches(|c| c == '.' || c == ':');
                if v6 {
                    if let Ok(ip) = t.parse::<std::net::Ipv6Addr>() { return Some(ip.to_string()); }
                } else if let Ok(ip) = t.parse::<std::net::Ipv4Addr>() { return Some(ip.to_string()); }
                token.clear();
            }
        }
    }
    if !token.is_empty() {
        let t = token.trim_matches(|c| c == '.' || c == ':');
        if v6 {
            if let Ok(ip) = t.parse::<std::net::Ipv6Addr>() { return Some(ip.to_string()); }
        } else if let Ok(ip) = t.parse::<std::net::Ipv4Addr>() { return Some(ip.to_string()); }
    }
    None
}

pub fn info(args: &Value) -> Result<Value, String> {
    let path = args["path"].as_str().unwrap_or("");
    if path.is_empty() {
        return Err("缺少库路径".into());
    }
    let local = Path::new(path).exists();
    let entries = load(path);
    let mut source = String::new();
    let mut updated: u64 = 0;
    if local {
        if let Ok(text) = fs::read_to_string(path) {
            for line in text.lines().take(4) {
                if let Some(v) = line.strip_prefix("#source\t") {
                    source = v.to_string();
                }
                if let Some(v) = line.strip_prefix("#updated\t") {
                    updated = v.parse().unwrap_or(0);
                }
            }
        }
    }
    Ok(json!({
        "builtin": !local,
        "path": path,
        "count": entries.len(),
        "source": if source.is_empty() {
            if local { "本地 IP 库".to_string() } else { "内置国家/地区库".to_string() }
        } else { source },
        "updated": updated,
        "size": fs::metadata(path).map(|m| m.len()).unwrap_or(0),
    }))
}

pub fn lookup(args: &Value) -> Result<Value, String> {
    let ip = args["ip"].as_str().ok_or("缺少 IP")?;
    let ipn = ipv4(ip).ok_or("仅支持 IPv4 地址")?;
    let path = args["path"].as_str().unwrap_or("");
    let entries = load(path);
    match find(&entries, ipn) {
        Some(e) => Ok(json!({
            "found": true,
            "ip": ip,
            "country_code": e.country,
            "country": country_name(&e.country),
            "region": e.region,
            "city": e.city,
            "isp": e.isp,
            "range": format!("{} - {}", u32ip(e.start), u32ip(e.end)),
            "builtin": !Path::new(path).exists(),
        })),
        None => Ok(json!({"found": false, "ip": ip, "builtin": !Path::new(path).exists()})),
    }
}

pub fn lookup_many(args: &Value) -> Result<Value, String> {
    let ips: Vec<String> = args["ips"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect()).unwrap_or_default();
    let path = args["path"].as_str().unwrap_or("");
    let entries = load(path);
    let builtin = !Path::new(path).exists();
    let mut out = Vec::with_capacity(ips.len());
    for ip in ips {
        match ipv4(&ip).and_then(|n| find(&entries, n)) {
            Some(e) => out.push(json!({
                "ip": ip, "found": true, "country_code": e.country,
                "country": country_name(&e.country), "region": e.region,
                "city": e.city, "isp": e.isp,
                "range": format!("{} - {}", u32ip(e.start), u32ip(e.end)), "builtin": builtin,
            })),
            None => out.push(json!({"ip": ip, "found": false, "builtin": builtin})),
        }
    }
    Ok(json!({"items": out, "builtin": builtin}))
}

pub fn update(args: &Value) -> Result<Value, String> {
    let path = args["path"].as_str().ok_or("缺少库路径")?;
    let url = args["url"].as_str().ok_or("缺少更新地址")?;
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("更新地址必须是 http/https".into());
    }
    let mut req = Req::new("GET", url);
    req.read_timeout = Duration::from_secs(45);
    req.connect_timeout = Duration::from_secs(10);
    req.headers.push(("Accept-Encoding".into(), "identity".into()));
    let mut resp = send(&req, &http_cache())?;
    if resp.status != 200 {
        return Err(format!("下载失败 HTTP {}", resp.status));
    }
    let mut raw = Vec::new();
    let mut limited = resp.reader.take(256 * 1024 * 1024);
    limited.read_to_end(&mut raw).map_err(|e| format!("读取失败: {}", e))?;
    let text = if raw.starts_with(&[0x1f, 0x8b]) {
        let mut dec = flate2::read::GzDecoder::new(&raw[..]);
        let mut t = String::new();
        dec.read_to_string(&mut t).map_err(|e| format!("解压失败: {}", e))?;
        t
    } else {
        String::from_utf8_lossy(&raw).to_string()
    };
    let entries = parse_db(&text);
    if entries.is_empty() {
        return Err("未解析到有效的 IP 段，请确认是 CSV / CSV.GZ".into());
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let mut out = String::with_capacity(entries.len() * 28);
    out.push_str(&format!("#source\t{}\n#updated\t{}\n#count\t{}\n", url, now, entries.len()));
    for e in &entries {
        out.push_str(&format!("{}\t{}\t{}\t{}\t{}\t{}\n", e.start, e.end, e.country, e.region, e.city, e.isp));
    }
    if let Some(dir) = Path::new(path).parent() {
        let _ = fs::create_dir_all(dir);
    }
    let tmp = format!("{}.tmp", path);
    fs::write(&tmp, out).map_err(|e| format!("写入失败: {}", e))?;
    fs::rename(&tmp, path).map_err(|e| format!("保存失败: {}", e))?;
    if let Some(c) = CACHE.get_or_init(|| Mutex::new(None)).lock().unwrap().as_mut() {
        c.key.clear();
    }
    Ok(json!({"ok": true, "count": entries.len(), "bytes": raw.len(), "updated": now, "source": url}))
}

/// 当前出口 IP：分别请求 IPv4 与 IPv6 探测端点，任一失败不影响另一个。
fn probe_group(v6: bool, urls: &[&str]) -> Value {
    let started = Instant::now();
    let mut ip = String::new();
    let mut source = String::new();
    let mut errors = Vec::new();
    for url in urls {
        if started.elapsed() > Duration::from_secs(9) {
            errors.push("探测总超时".to_string());
            break;
        }
        let mut req = Req::new("GET", url);
        req.read_timeout = Duration::from_secs(4);
        req.connect_timeout = Duration::from_secs(3);
        match send(&req, &http_cache()) {
            Ok(mut r) if r.status == 200 => {
                let mut body = String::new();
                if r.reader.take(512 * 1024).read_to_string(&mut body).is_ok() {
                    if let Some(found) = extract_ip(&body, v6) {
                        ip = found;
                        source = (*url).to_string();
                        break;
                    }
                    errors.push(format!("{} 返回内容无 {} 地址", url, if v6 { "IPv6" } else { "IPv4" }));
                }
            }
            Ok(r) => errors.push(format!("{} HTTP {}", url, r.status)),
            Err(e) => errors.push(format!("{}: {}", url, e)),
        }
    }
    json!({"ip": ip, "source": source, "errors": errors})
}

/// 当前出口探测：IPv4 分「国内探测 / 外部探测」，IPv6 走外部探测。
/// 四个探测任务并发执行，避免多个慢接口串联拖长首页刷新。
pub fn egress(_args: &Value) -> Result<Value, String> {
    let specs: Vec<(&str, bool, Vec<&str>)> = vec![
        ("ipv4_cn", false, vec![
            "https://myip.ipip.net",
            "https://my.ip.cn/",
        ]),
        ("ipv4_intl", false, vec![
            "https://api.ipify.org?format=json",
            "https://ipinfo.io/ip",
            "https://api.ip.sb/jsonip",
            "https://www.cloudflare.com/cdn-cgi/trace",
            "https://ifconfig.me/ip",
        ]),
        ("ipv6_intl", true, vec![
            "https://api6.ipify.org?format=json",
            "https://v6.ident.me/",
            "https://www.cloudflare.com/cdn-cgi/trace",
            "https://ifconfig.me/ip",
        ]),
    ];
    let mut handles = Vec::new();
    for (key, v6, urls) in specs {
        handles.push(thread::spawn(move || (key, probe_group(v6, &urls))));
    }
    let mut probes = serde_json::Map::new();
    let mut errors = Vec::new();
    for h in handles {
        if let Ok((key, value)) = h.join() {
            if let Some(list) = value["errors"].as_array() {
                for e in list {
                    if let Some(text) = e.as_str() {
                        errors.push(format!("{}: {}", key, text));
                    }
                }
            }
            probes.insert(key.to_string(), value);
        }
    }
    let ipv4_cn = probes.get("ipv4_cn").and_then(|v| v["ip"].as_str()).unwrap_or("").to_string();
    let ipv4_intl = probes.get("ipv4_intl").and_then(|v| v["ip"].as_str()).unwrap_or("").to_string();
    let ipv6 = probes.get("ipv6_intl").and_then(|v| v["ip"].as_str()).unwrap_or("").to_string();
    let ipv4 = if !ipv4_cn.is_empty() { ipv4_cn.clone() } else { ipv4_intl.clone() };
    Ok(json!({
        "ipv4": ipv4,
        "ipv4_cn": ipv4_cn,
        "ipv4_intl": ipv4_intl,
        "ipv6": ipv6,
        "probes": probes,
        "errors": errors,
    }))
}

/// 域名解析：同时返回 A 与 AAAA，带 DNS 服务器与耗时。
pub fn resolve_host(args: &Value) -> Result<Value, String> {
    let host = args["host"].as_str().ok_or("缺少域名")?;
    let servers: Vec<String> = args["servers"].as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_else(|| vec!["223.5.5.5".into(), "119.29.29.29".into()]);
    let mut out = json!({"host": host, "ipv4": [], "ipv6": []});
    for (key, qtype) in [("ipv4", 1u16), ("ipv6", 28u16)] {
        match crate::dns::resolve_with_servers(host, &servers, qtype, Duration::from_secs(4), 0) {
            Ok(a) => {
                let items: Vec<Value> = a.ips.iter().map(|ip| json!({
                    "ip": ip.to_string(), "server": a.server, "ms": a.elapsed_ms
                })).collect();
                out[key] = json!(items);
            }
            Err(e) => {
                out[key] = json!([]);
                out["error"] = json!(e);
            }
        }
    }
    Ok(out)
}


fn fetch_json(url: &str) -> Result<Value, String> {
    let mut req = Req::new("GET", url);
    req.read_timeout = Duration::from_secs(8);
    req.connect_timeout = Duration::from_secs(5);
    req.headers.push(("Accept".into(), "application/json".into()));
    let mut resp = send(&req, &http_cache())?;
    if resp.status != 200 {
        return Err(format!("HTTP {}", resp.status));
    }
    let mut body = String::new();
    resp.reader.take(2 * 1024 * 1024).read_to_string(&mut body).map_err(|e| e.to_string())?;
    serde_json::from_str(body.trim()).map_err(|e| format!("响应不是 JSON: {}", e))
}

fn normalize_api(ip: &str, d: &Value) -> Option<Value> {
    let s = |k: &str| d[k].as_str().unwrap_or("").to_string();
    let n = |k: &str| d[k].as_f64().map(|v| v.to_string()).unwrap_or_default();
    // ip-api.com 原格式
    if d["status"].as_str() == Some("success") {
        let mut out = d.clone();
        out["query"] = json!(ip);
        out["status"] = json!("success");
        return Some(out);
    }
    // ipwho.is
    if d["success"].as_bool() == Some(true) {
        let conn = &d["connection"];
        let tz = &d["timezone"];
        return Some(json!({
            "status": "success", "query": ip,
            "country": s("country"), "countryCode": s("country_code"),
            "regionName": s("region"), "city": s("city"),
            "isp": conn["isp"].as_str().unwrap_or(""),
            "org": conn["org"].as_str().unwrap_or(""),
            "as": conn["asn"].as_u64().map(|v| format!("AS{}", v)).unwrap_or_default(),
            "lat": d["latitude"].as_f64().unwrap_or(0.0),
            "lon": d["longitude"].as_f64().unwrap_or(0.0),
            "timezone": tz["id"].as_str().unwrap_or(""),
        }));
    }
    // ipapi.co
    if !s("country_code").is_empty() && (!s("ip").is_empty() || d["ip"].is_null()) {
        return Some(json!({
            "status": "success", "query": ip,
            "country": s("country_name"), "countryCode": s("country_code"),
            "regionName": s("region"), "city": s("city"),
            "isp": s("org"), "org": s("org"), "as": s("asn"),
            "lat": d["latitude"].as_f64().unwrap_or(0.0),
            "lon": d["longitude"].as_f64().unwrap_or(0.0),
            "timezone": s("timezone"),
        }));
    }
    // ipinfo.io
    if !s("country").is_empty() && s("country").len() == 2 {
        let loc = s("loc");
        let mut lat = String::new();
        let mut lon = String::new();
        if let Some((a, b)) = loc.split_once(',') { lat = a.to_string(); lon = b.to_string(); }
        return Some(json!({
            "status": "success", "query": ip,
            "country": "", "countryCode": s("country"),
            "regionName": s("region"), "city": s("city"),
            "isp": s("org"), "org": s("org"), "as": s("org"),
            "lat": lat, "lon": lon, "timezone": s("timezone"),
        }));
    }
    let _ = n("latitude");
    None
}

fn api_auto_one(ip: &str, custom: Option<&str>) -> Result<Value, String> {
    let mut last = "在线 API 无结果".to_string();
    if let Some(ep) = custom.filter(|v| !v.trim().is_empty()) {
        let url = if ep.contains("{ip}") {
            ep.replace("{ip}", ip)
        } else if ep.contains("%s") {
            ep.replace("%s", ip)
        } else {
            format!("{}{}", ep, if ep.contains('?') { format!("&ip={}", ip) } else { format!("?ip={}", ip) })
        };
        match fetch_json(&url).and_then(|v| normalize_api(ip, &v).ok_or("自定义 API 字段不兼容".to_string())) {
            Ok(v) => return Ok(v),
            Err(e) => last = e,
        }
    }
    // 预制在线源：ip-api、ipwho.is、ipapi.co、ipinfo.io，逐个回退。
    for url in [
        format!("http://ip-api.com/json/{}?fields=status,message,country,countryCode,regionName,city,isp,org,as,lat,lon,timezone,query&lang=zh-CN", ip),
        format!("https://ipwho.is/{}", ip),
        format!("https://ipapi.co/{}/json/", ip),
        format!("https://ipinfo.io/{}/json", ip),
    ] {
        match fetch_json(&url) {
            Ok(v) => {
                if let Some(out) = normalize_api(ip, &v) {
                    return Ok(out);
                }
                last = format!("{} 字段不兼容", url);
            }
            Err(e) => last = format!("{}: {}", url, e),
        }
    }
    Err(last)
}

/// 单个 IP：预制多在线源逐个回退，失败后由 Flutter 使用离线库兜底。
pub fn api_auto(args: &Value) -> Result<Value, String> {
    let ip = args["ip"].as_str().ok_or("缺少 IP")?;
    let data = api_auto_one(ip, args["endpoint"].as_str())?;
    Ok(json!({"ok": true, "data": data}))
}

/// 批量在线查询；每个 IP 在线源并发，互不阻塞。
pub fn api_auto_batch(args: &Value) -> Result<Value, String> {
    let ips: Vec<String> = args["ips"].as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();
    if ips.is_empty() { return Ok(json!({"items": []})); }
    let custom = args["endpoint"].as_str().map(|s| s.to_string());
    let mut handles = Vec::new();
    for ip in ips.iter().take(60).cloned() {
        let custom = custom.clone();
        handles.push(thread::spawn(move || {
            api_auto_one(&ip, custom.as_deref()).unwrap_or(Value::Null)
        }));
    }
    let mut items = Vec::new();
    for h in handles {
        if let Ok(v) = h.join() {
            if !v.is_null() { items.push(v); }
        }
    }
    Ok(json!({"items": items, "requested": ips.len()}))
}

/// 批量 IP API（ip-api batch）：一次请求返回多个 IP 的国家/省/市/ISP。
pub fn api_batch(args: &Value) -> Result<Value, String> {
    let ips: Vec<String> = args["ips"].as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();
    if ips.is_empty() { return Ok(json!({"items": []})); }
    let endpoint = args["endpoint"].as_str().unwrap_or("");
    let base = if endpoint.contains("ip-api.com") {
        let scheme = if endpoint.starts_with("https://") { "https" } else { "http" };
        format!("{}://ip-api.com/batch", scheme)
    } else {
        "http://ip-api.com/batch".to_string()
    };
    let url = format!("{}?fields=status,message,country,countryCode,regionName,city,isp,org,as,lat,lon,timezone,query&lang=zh-CN", base);
    let body = serde_json::to_vec(&ips).map_err(|e| e.to_string())?;
    let mut req = Req::new("POST", &url);
    req.read_timeout = Duration::from_secs(12);
    req.connect_timeout = Duration::from_secs(6);
    req.headers.push(("Content-Type".into(), "application/json".into()));
    req.headers.push(("Accept".into(), "application/json".into()));
    req.body = Some(body);
    let mut resp = send(&req, &http_cache())?;
    if resp.status != 200 {
        return Err(format!("HTTP {}", resp.status));
    }
    let mut text = String::new();
    resp.reader.take(4 * 1024 * 1024).read_to_string(&mut text).map_err(|e| e.to_string())?;
    let data: Value = serde_json::from_str(text.trim()).map_err(|e| format!("响应不是 JSON: {}", e))?;
    let items = data.as_array().cloned().unwrap_or_default();
    Ok(json!({"items": items, "requested": ips.len()}))
}


/// IP 类型 / 原生检测：ipinfo demo 的 ASN type、privacy、anycast 与注册国对比。
pub fn ip_type(args: &Value) -> Result<Value, String> {
    let ip = args["ip"].as_str().ok_or("缺少 IP")?;
    let url = format!("https://ipinfo.io/widget/demo/{}", ip);
    let mut req = Req::new("GET", &url);
    req.read_timeout = Duration::from_secs(8);
    req.connect_timeout = Duration::from_secs(4);
    req.headers.push(("Accept".into(), "application/json".into()));
    let mut resp = send(&req, &http_cache())?;
    if resp.status != 200 { return Err(format!("HTTP {}", resp.status)); }
    let mut body = String::new();
    resp.reader.take(4 * 1024 * 1024).read_to_string(&mut body).map_err(|e| e.to_string())?;
    let root: Value = serde_json::from_str(body.trim()).map_err(|e| format!("响应不是 JSON: {}", e))?;
    let d = &root["data"];
    if d.is_null() { return Ok(json!({"found": false, "ip": ip})); }
    let country = d["country"].as_str().unwrap_or("");
    let abuse_country = d["abuse"]["country"].as_str().unwrap_or("");
    let anycast = d["is_anycast"].as_bool().unwrap_or(false);
    let mobile = d["is_mobile"].as_bool().unwrap_or(false);
    let asn_type = d["asn"]["type"].as_str().unwrap_or("").to_ascii_lowercase();
    let hosting = d["privacy"]["hosting"].as_bool().unwrap_or(false) || asn_type == "hosting";
    let vpn = d["privacy"]["vpn"].as_bool().unwrap_or(false);
    let proxy = d["privacy"]["proxy"].as_bool().unwrap_or(false);
    let tor = d["privacy"]["tor"].as_bool().unwrap_or(false);
    let relay = d["privacy"]["relay"].as_bool().unwrap_or(false);
    let type_label = if mobile {
        "移动网络"
    } else if hosting {
        "数据中心 IP"
    } else {
        match asn_type.as_str() {
            "isp" => "家庭宽带 / ISP",
            "business" => "企业网络",
            "education" => "教育网络",
            "government" => "政府网络",
            _ => "未知类型",
        }
    };
    let (native, native_label) = if anycast {
        (Some(false), "Anycast · 非原生")
    } else if !abuse_country.is_empty() && !country.is_empty() && abuse_country != country {
        (Some(false), "广播 IP · 非原生")
    } else if !abuse_country.is_empty() && !country.is_empty() {
        (Some(true), "原生 IP")
    } else {
        (None, "原生状态未知")
    };
    let mut score: i32 = 100;
    if hosting { score -= 42; }
    if vpn { score -= 35; }
    if proxy { score -= 35; }
    if tor { score -= 60; }
    if relay { score -= 20; }
    if anycast { score -= 8; }
    score = score.clamp(0, 100);
    Ok(json!({
        "found": true, "ip": ip,
        "type": type_label, "asn_type": asn_type,
        "datacenter": hosting, "native": native, "native_label": native_label,
        "anycast": anycast, "mobile": mobile,
        "privacy": {"vpn": vpn, "proxy": proxy, "tor": tor, "relay": relay, "hosting": hosting},
        "purity": score,
        "asn": d["asn"]["asn"].as_str().unwrap_or(""),
        "asn_name": d["asn"]["name"].as_str().unwrap_or(""),
        "org": d["org"].as_str().unwrap_or(""),
        "country": country, "registered_country": abuse_country,
        "city": d["city"].as_str().unwrap_or(""),
        "region": d["region"].as_str().unwrap_or(""),
    }))
}

pub fn api(args: &Value) -> Result<Value, String> {
    let ip = args["ip"].as_str().ok_or("缺少 IP")?;
    let endpoint = args["endpoint"].as_str().filter(|s| !s.is_empty())
        .unwrap_or("http://ip-api.com/json/{ip}?fields=status,message,country,regionName,city,isp,org,as,lat,lon,timezone,query&lang=zh-CN");
    let url = if endpoint.contains("{ip}") {
        endpoint.replace("{ip}", ip)
    } else if endpoint.contains("%s") {
        endpoint.replace("%s", ip)
    } else {
        format!("{}{}", endpoint, if endpoint.contains('?') { format!("&ip={}", ip) } else { format!("?ip={}", ip) })
    };
    let mut req = Req::new("GET", &url);
    req.read_timeout = Duration::from_secs(10);
    req.connect_timeout = Duration::from_secs(6);
    req.headers.push(("Accept".into(), "application/json".into()));
    let mut resp = send(&req, &http_cache())?;
    if resp.status != 200 {
        return Err(format!("HTTP {}", resp.status));
    }
    let mut body = String::new();
    resp.reader.take(2 * 1024 * 1024).read_to_string(&mut body).map_err(|e| e.to_string())?;
    let data: Value = serde_json::from_str(body.trim()).map_err(|e| format!("响应不是 JSON: {}", e))?;
    Ok(json!({"ok": true, "endpoint": url, "data": data}))
}
