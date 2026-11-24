//! 多格式本地 IP 库引擎。
//!
//! 统一支持六种数据库，按文件头魔数自动识别：
//! - NetPulse TSV（自有数字区间格式）
//! - 通用 CSV / CSV.GZ（GeoLite2 / DB-IP City & Country、IP2Location LITE 等常见列布局）
//! - 纯真 IP 库 qqwry.dat（GBK，中文城市/运营商）
//! - ip2region xdb v4（城市级，中文 region 管道格式）
//! - IP2Proxy LITE BIN（PX1–PX12，代理类型 + 归属地）
//! - MaxMind GeoLite2 .mmdb（IPv4 / IPv6 双栈树，含 IPv4-mapped 跳转）
//!
//! 全部解析为统一的 `Entry` 列表后交给上层二分查找。

use serde_json::{json, Value};
use std::io::Read;

/// 单条 IPv4 归属记录（区间闭合 [start, end]）。
#[derive(Clone, Debug)]
pub struct Entry {
    pub start: u32,
    pub end: u32,
    pub country: String,
    pub region: String,
    pub city: String,
    pub isp: String,
    /// 附加信息：代理类型（IP2Proxy）或库来源标记。
    pub extra: String,
    pub lat: String,
    pub lon: String,
}

pub fn ipv4(s: &str) -> Option<u32> {
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

#[allow(dead_code)]
pub fn u32ip(v: u32) -> String {
    format!("{}.{}.{}.{}", v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255)
}

// ---------------- 格式识别 ----------------

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum DbKind {
    NetpulseTsv,
    Qqwry,
    Xdb,
    Ip2Proxy,
    Mmdb,
    Csv,
    Unknown,
}

/// 按文件头 + 扩展名识别库类型。head 为文件前 64 字节。
pub fn detect_kind(path: &str, head: &[u8], size: u64) -> DbKind {
    // 1) 魔数优先
    if head.len() >= 8 && head[0] == 0xba && head[1] == 0xfa && size > 512 {
        // 纯真：头 3 字节 = 第一条索引的绝对偏移（小端），典型 ~64250。
        let off = head[0] as u32 | (head[1] as u32) << 8 | (head[2] as u32) << 16;
        if off > 8 && (off as u64) < size {
            return DbKind::Qqwry;
        }
    }
    if head.len() >= 4 && head[0] == 0x03 && head[1] == 0x00 && head[2] == 0x01 && head[3] == 0x00 {
        return DbKind::Xdb;
    }
    if head.len() >= 2 && head[0] == 0x1f && head[1] == 0x8b {
        return DbKind::Csv; // gz 文本，解压后按 CSV 处理
    }
    if head.len() >= 16 && &head[0..10] == b"MaxMind.co" {
        return DbKind::Mmdb;
    }
    if head.len() >= 32 {
        let dbtype = head[0];
        let year = head[2];
        // IP2Proxy BIN：type 1..=12（PX1..PX12），release year >= 14（2014+）
        if (1..=12).contains(&dbtype) && (14..=60).contains(&year) {
            return DbKind::Ip2Proxy;
        }
    }
    // 2) 扩展名辅助
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".dat") {
        return DbKind::Qqwry;
    }
    if lower.ends_with(".xdb") {
        return DbKind::Xdb;
    }
    if lower.ends_with(".mmdb") {
        return DbKind::Mmdb;
    }
    if lower.ends_with(".bin") {
        return DbKind::Ip2Proxy;
    }
    if lower.ends_with(".tsv") {
        return DbKind::NetpulseTsv;
    }
    // 3) 文本启发式：首行是多列文本
    if let Ok(text) = std::str::from_utf8(&head[..head.len().min(64)]) {
        let first = text.lines().next().unwrap_or("");
        if !first.is_empty() && (first.split('\t').count() >= 3 || first.split(',').count() >= 3) {
            return DbKind::Csv;
        }
    }
    DbKind::Unknown
}

// ---------------- 解析：通用 CSV / NetPulse TSV ----------------

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

/// 通用 CSV：
/// - GeoLite2/DB-IP City num: start,end,country,state1,state2,city,postcode,lat,lon,tz
/// - GeoLite2 Country num: start,end,country
/// - IP2Location LITE DB1: start,end,country,country_long（带引号）
type CsvCols = Option<(usize, usize, usize, usize, usize, usize, usize, usize)>;

fn parse_csv_text(text: &str) -> Vec<Entry> {
    let mut entries: Vec<Entry> = Vec::new();
    let mut cols: CsvCols = None;
    for line in text.lines() {
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
                    keys.iter().any(|k| h == *k || h.contains(k))
                })
            };
            let start = get(&["ip_range_start", "range_start", "start"]).unwrap_or(0);
            let end = get(&["ip_range_end", "range_end", "end"]).unwrap_or(1);
            let country = get(&["country_code", "country"]).unwrap_or(2.min(f.len() - 1));
            let region = get(&["state1", "region_name", "region"]).unwrap_or(3.min(f.len() - 1));
            let city = get(&["city_name", "city"]).unwrap_or(4.min(f.len() - 1));
            let isp = get(&["isp", "organization", "org"]).unwrap_or(5.min(f.len() - 1));
            let lat = get(&["latitude", "lat"]).unwrap_or(usize::MAX);
            let lon = get(&["longitude", "lon"]).unwrap_or(usize::MAX);
            cols = Some((start, end, country, region, city, isp, lat, lon));
            continue;
        }
        let (si, ei, ci, ri, mi, ii, lati, loni) = cols.unwrap_or((0, 1, 2, 3, 4, 5, 7, 8));
        if f.len() <= si.max(ei) {
            continue;
        }
        let start = ipv4(&f[si]).or_else(|| f[si].parse::<u32>().ok());
        let end = ipv4(&f[ei]).or_else(|| f[ei].parse::<u32>().ok());
        if let (Some(s), Some(e)) = (start, end) {
            if e >= s {
                let take = |idx: usize| {
                    if idx < f.len() {
                        f[idx].clone()
                    } else {
                        String::new()
                    }
                };
                entries.push(Entry {
                    start: s,
                    end: e,
                    country: take(ci),
                    region: take(ri),
                    city: take(mi),
                    isp: take(ii),
                    extra: String::new(),
                    lat: if lati < f.len() { f[lati].clone() } else { String::new() },
                    lon: if loni < f.len() { f[loni].clone() } else { String::new() },
                });
            }
        }
        if entries.len() > 3_200_000 {
            break;
        }
    }
    entries.sort_by_key(|e| e.start);
    entries
}

/// NetPulse 自有 TSV：数字区间起步 + # 头部注释。
fn parse_netpulse_tsv(text: &str) -> Vec<Entry> {
    let mut entries: Vec<Entry> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 {
            continue;
        }
        let (Some(s), Some(e)) = (f[0].parse::<u32>().ok(), f[1].parse::<u32>().ok()) else {
            continue;
        };
        if e < s {
            continue;
        }
        entries.push(Entry {
            start: s,
            end: e,
            country: f.get(2).unwrap_or(&"").to_string(),
            region: f.get(3).unwrap_or(&"").to_string(),
            city: f.get(4).unwrap_or(&"").to_string(),
            isp: f.get(5).unwrap_or(&"").to_string(),
            extra: String::new(),
            lat: String::new(),
            lon: String::new(),
        });
        if entries.len() > 3_200_000 {
            break;
        }
    }
    entries.sort_by_key(|e| e.start);
    entries
}

// ---------------- 解析：纯真 qqwry.dat ----------------

mod gb2312;

/// GBK 解码（GB2312 全区 + ASCII；扩展区降级 '?'）。
fn gbk_decode(bytes: &[u8]) -> String {
    let mut out = String::new();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b < 0x80 {
            out.push(b as char);
            i += 1;
        } else if i + 1 < bytes.len() {
            out.push_str(&gb2312::decode_two(b, bytes[i + 1]));
            i += 2;
        } else {
            break;
        }
    }
    out
}

struct Qqwry<'a> {
    data: &'a [u8],
}

impl<'a> Qqwry<'a> {
    fn u24(&self, off: usize) -> usize {
        let d = self.data;
        if off + 3 > d.len() {
            return 0;
        }
        d[off] as usize | (d[off + 1] as usize) << 8 | (d[off + 2] as usize) << 16
    }
    fn u32(&self, off: usize) -> u32 {
        let d = self.data;
        if off + 4 > d.len() {
            return 0;
        }
        u32::from_le_bytes([d[off], d[off + 1], d[off + 2], d[off + 3]])
    }
    /// 读取以 \0 结尾的字符串区域，支持重定向（0x01/0x02 模式）。
    fn zone(&self, off: usize, depth: u8) -> String {
        let d = self.data;
        if off >= d.len() || depth > 3 {
            return String::new();
        }
        match d[off] {
            0x01 => self.zone(self.u24(off + 1), depth + 1),
            0x02 => self.zone(self.u24(off + 1), depth + 1),
            _ => {
                let end = d[off..]
                    .iter()
                    .position(|&b| b == 0)
                    .map(|p| off + p)
                    .unwrap_or(d.len());
                gbk_decode(&d[off..end])
            }
        }
    }
    /// 解析「国家 + 区域」，返回 (country, area)。
    fn country_area(&self, off: usize) -> (String, String) {
        let d = self.data;
        if off >= d.len() {
            return (String::new(), String::new());
        }
        match d[off] {
            0x01 => self.country_area(self.u24(off + 1)),
            0x02 => {
                let country = self.zone(self.u24(off + 1), 1);
                let area_off = off + 4;
                let area = if area_off < d.len() {
                    match d[area_off] {
                        0x01 | 0x02 => self.zone(self.u24(area_off + 1), 1),
                        _ => self.zone(area_off, 1),
                    }
                } else {
                    String::new()
                };
                (country, area)
            }
            _ => {
                let end = d[off..]
                    .iter()
                    .position(|&b| b == 0)
                    .map(|p| off + p)
                    .unwrap_or(d.len());
                let country = gbk_decode(&d[off..end]);
                let after = end + 1;
                let area = if after < d.len() {
                    match d[after] {
                        0x01 | 0x02 => self.zone(self.u24(after + 1), 1),
                        _ => self.zone(after, 1),
                    }
                } else {
                    String::new()
                };
                (country, area)
            }
        }
    }
}

/// 纯真 area 常见格式「广东省深圳市 电信」；按 ISP 关键词切分。
fn split_qq_area(area: &str) -> (String, String) {
    let a = area.trim();
    if a.is_empty() || a == "CZ88.NET" {
        return (String::new(), String::new());
    }
    const ISPS: [&str; 20] = [
        "电信", "联通", "移动", "铁通", "网通", "教育网", "科技网", "长城宽带",
        "阿里云", "腾讯云", "华为云", "百度云", "金山云", "青云", "UCloud",
        "亚马逊", "Azure", "Oracle", "Amazon", "数据中心",
    ];
    for isp in ISPS {
        if let Some(pos) = a.rfind(isp) {
            if pos > 0 {
                let region = a[..pos].trim();
                let tail = &a[pos..];
                let isp_part = if tail.len() > isp.len() { tail.trim() } else { isp };
                return (region.to_string(), isp_part.to_string());
            }
        }
    }
    (a.to_string(), String::new())
}

fn parse_qqwry(data: &[u8]) -> Vec<Entry> {
    let mut entries = Vec::new();
    if data.len() < 16 {
        return entries;
    }
    // 新版（2022+，CZDB 重制）：8 字节头 = u32 索引区起点 + u32 末条索引偏移，
    // 记录格式 geoOffset → end_ip(u32) + country/area（经典重定向规则）。
    // 旧版：3+3 字节头，geoOffset → country/area 直接开始，end_ip = 下一索引 start-1。
    let u32_first = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let u32_last = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as usize;
    let new_header = u32_first > 8
        && u32_first < data.len()
        && u32_last >= u32_first
        && u32_last + 7 <= data.len()
        && (u32_last - u32_first).is_multiple_of(7);
    let (first, last, new_fmt) = if new_header {
        (u32_first, u32_last, true)
    } else {
        let f = data[0] as usize | (data[1] as usize) << 8 | (data[2] as usize) << 16;
        let l = data[3] as usize | (data[4] as usize) << 8 | (data[5] as usize) << 16;
        (f, l, false)
    };
    if first < 8 || last < first || last + 7 > data.len() {
        return entries;
    }
    let count = (last - first) / 7 + 1;
    let qq = Qqwry { data };
    for i in 0..count {
        let rec = first + i * 7;
        if rec + 7 > data.len() {
            break;
        }
        let start = qq.u32(rec);
        let geo = qq.u24(rec + 4);
        if geo == 0 || geo >= data.len() {
            continue;
        }
        let (end, area_off) = if new_fmt {
            let e = qq.u32(geo);
            (e, geo + 4)
        } else {
            // 旧版：没有显式 end，用下一条 start-1 封顶
            let next_start = if i + 1 < count {
                let r2 = first + (i + 1) * 7;
                if r2 + 4 <= data.len() {
                    qq.u32(r2)
                } else {
                    u32::MAX
                }
            } else {
                u32::MAX
            };
            (next_start.saturating_sub(1), geo)
        };
        if end < start {
            continue;
        }
        let (country, area) = qq.country_area(area_off);
        let (region_city, isp) = split_qq_area(&area);
        entries.push(Entry {
            start,
            end,
            country: country.trim().replace('\u{2013}', "-").to_string(),
            region: region_city.replace('\u{2013}', "-"),
            city: String::new(),
            isp,
            extra: String::new(),
            lat: String::new(),
            lon: String::new(),
        });
        if entries.len() > 1_700_000 {
            break;
        }
    }
    entries.sort_by_key(|e| e.start);
    entries
}

// ---------------- 解析：ip2region xdb v4 ----------------

const XDB_HEADER_LEN: usize = 256;
const XDB_VECTOR_COLS: usize = 256;
const XDB_VECTOR_SIZE: usize = 8;
const XDB_V4_SEG: usize = 14;

fn parse_xdb(data: &[u8]) -> Vec<Entry> {
    let mut entries = Vec::new();
    if data.len() < XDB_HEADER_LEN + XDB_VECTOR_COLS * XDB_VECTOR_SIZE {
        return entries;
    }
    // 收集 vector index 指向的全部索引页并归并。
    let mut spans: Vec<(usize, usize)> = Vec::new();
    for i in 0..XDB_VECTOR_COLS {
        for j in 0..XDB_VECTOR_COLS {
            let o = XDB_HEADER_LEN + (i * XDB_VECTOR_COLS + j) * XDB_VECTOR_SIZE;
            let s = u32::from_le_bytes([data[o], data[o + 1], data[o + 2], data[o + 3]]) as usize;
            let e =
                u32::from_le_bytes([data[o + 4], data[o + 5], data[o + 6], data[o + 7]]) as usize;
            if s != 0 && e >= s && e + XDB_V4_SEG <= data.len() {
                spans.push((s, e));
            }
        }
    }
    spans.sort_unstable();
    spans.dedup();
    for (s, _e) in spans {
        let mut p = s;
        while p + XDB_V4_SEG <= data.len() {
            let ipf = u32::from_le_bytes([data[p], data[p + 1], data[p + 2], data[p + 3]]);
            let ipt = u32::from_le_bytes([data[p + 4], data[p + 5], data[p + 6], data[p + 7]]);
            if ipt < ipf {
                break;
            }
            let data_len = u16::from_le_bytes([data[p + 8], data[p + 9]]) as usize;
            let data_ptr = u32::from_le_bytes([
                data[p + 10],
                data[p + 11],
                data[p + 12],
                data[p + 13],
            ]) as usize;
            let region = if data_len > 0 && data_ptr + data_len <= data.len() {
                String::from_utf8_lossy(&data[data_ptr..data_ptr + data_len]).to_string()
            } else {
                String::new()
            };
            // region 格式：国家|区域|省份|城市|ISP|国家代码
            let parts: Vec<&str> = region.split('|').collect();
            let take = |i: usize| parts.get(i).copied().unwrap_or("").to_string();
            let province = take(2);
            let city = take(3);
            let region = if province == city || province.is_empty() {
                city.clone()
            } else if city.is_empty() {
                province.clone()
            } else {
                format!("{province} {city}")
            };
            entries.push(Entry {
                start: ipf,
                end: ipt,
                country: take(0),
                region,
                city,
                isp: take(4),
                extra: take(5),
                lat: String::new(),
                lon: String::new(),
            });
            if ipt == u32::MAX {
                break;
            }
            p += XDB_V4_SEG;
        }
        if entries.len() > 1_800_000 {
            break;
        }
    }
    entries.sort_by_key(|e| e.start);
    entries.dedup_by(|a, b| a.start == b.start && a.end == b.end);
    entries
}

// ---------------- 解析：IP2Proxy LITE BIN ----------------

/// PX 类型 → 列位置表（与官方 ip2proxy-c 一致；0 = 该类型不支持）。
const PX_COUNTRY: [u8; 13] = [0, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3];
const PX_REGION: [u8; 13] = [0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4];
const PX_CITY: [u8; 13] = [0, 0, 0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5];
const PX_ISP: [u8; 13] = [0, 0, 0, 0, 6, 6, 6, 6, 6, 6, 6, 6, 6];
const PX_PROXY_TYPE: [u8; 13] = [0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2];

fn parse_ip2proxy(data: &[u8]) -> Vec<Entry> {
    let mut entries = Vec::new();
    if data.len() < 64 {
        return entries;
    }
    let r32 = |o: usize| -> u32 {
        if o + 4 <= data.len() {
            u32::from_le_bytes([data[o], data[o + 1], data[o + 2], data[o + 3]])
        } else {
            0
        }
    };
    let dbtype = data[0] as usize;
    if dbtype == 0 || dbtype > 12 {
        return entries;
    }
    let col_off = (data[1] as usize) * 4;
    if col_off < 8 {
        return entries;
    }
    let count = r32(5) as usize;
    let base = r32(9) as usize;
    if base == 0 || base >= data.len() || count == 0 {
        return entries;
    }
    let row_size = col_off - 4;
    let cstr = |pos: u32| -> String {
        let p = pos as usize;
        if p == 0 || p >= data.len() {
            return String::new();
        }
        let n = data[p] as usize;
        if n == 0 || p + 1 + n > data.len() {
            return String::new();
        }
        String::from_utf8_lossy(&data[p + 1..p + 1 + n]).to_string()
    };
    let get = |row: &[u8], col: u8| -> String {
        if col == 0 {
            return String::new();
        }
        let at = 4 * (col as usize - 2);
        if at + 4 > row.len() {
            return String::new();
        }
        cstr(u32::from_le_bytes([row[at], row[at + 1], row[at + 2], row[at + 3]]))
    };
    for i in 0..count {
        // base 为 1-based（对齐官方 C 的 fseek(row_offset - 1)）；
        // 字符串偏移（cstr）保持 0-based（fseek(position)）。
        let o = base - 1 + i * col_off;
        if o + col_off + 4 > data.len() {
            break;
        }
        let ipf = r32(o);
        let ipt = r32(o + col_off);
        if ipt < ipf {
            continue;
        }
        let row = &data[o + 4..o + 4 + row_size];
        let clean = |s: String| if s == "-" { String::new() } else { s };
        entries.push(Entry {
            start: ipf,
            end: ipt,
            country: clean(get(row, PX_COUNTRY[dbtype])),
            region: clean(get(row, PX_REGION[dbtype])),
            city: clean(get(row, PX_CITY[dbtype])),
            isp: clean(get(row, PX_ISP[dbtype])),
            extra: clean(get(row, PX_PROXY_TYPE[dbtype])),
            lat: String::new(),
            lon: String::new(),
        });
        if entries.len() > 1_200_000 {
            break;
        }
    }
    entries.sort_by_key(|e| e.start);
    entries
}

// ---------------- 解析：MaxMind MMDB ----------------

/// MMDB 数据段解码：返回 (value 描述, 下一偏移)。指针在解码层直接解析。
#[derive(Debug, Clone)]
enum MmVal {
    Str(String),
    Uint(u64),
    Map(Vec<(String, MmVal)>),
    Arr(Vec<MmVal>),
    Other,
}

struct Mmdb<'a> {
    data: &'a [u8],
    /// 数据段绝对起点（search tree 结束 + 16 字节 separator）。
    data_start: usize,
    pointer_base: usize,
    node_count: usize,
    record_size: usize,
    ip_version: u32,
    /// IPv6 树中 IPv4 子树的起始节点。
    ipv4_start: usize,
}

const POINTER_OFFSETS: [usize; 4] = [0, 0, 2048, 526_336];

impl<'a> Mmdb<'a> {
    fn metadata_marker(&self) -> Option<usize> {
        const MARK: &[u8] = b"\xab\xcd\xefMaxMind.com";
        memmem(self.data, MARK)
    }

    fn parse_meta(&mut self) -> bool {
        let Some(mark) = self.metadata_marker() else { return false };
        let Some(ctrl) = self.data.get(mark + 14) else { return false };
        let ctrl = *ctrl;
        if ctrl >> 5 != 7 {
            return false;
        }
        let pairs = (ctrl & 0x1f) as usize;
        let mut pos = mark + 15;
        let mut node_count = 0usize;
        let mut record_size = 0usize;
        let mut ip_version = 4u32;
        for _ in 0..pairs {
            // key 必为 utf8 字符串（或指向字符串的指针）
            let (key, next) = match self.decode_at(pos, 0) {
                Some((MmVal::Str(s), n)) => (s, n),
                _ => return false,
            };
            let (value, next) = match self.decode_at(next, 0) {
                Some((v, n)) => (v, n),
                _ => return false,
            };
            pos = next;
            match key.as_str() {
                "node_count" => node_count = mm_as_uint(&value) as usize,
                "record_size" => record_size = mm_as_uint(&value) as usize,
                "ip_version" => ip_version = mm_as_uint(&value) as u32,
                _ => {}
            }
        }
        if node_count == 0 || !(24..=32).contains(&record_size) {
            return false;
        }
        if ip_version != 4 && ip_version != 6 {
            return false;
        }
        let node_bytes = record_size / 4; // 官方语义：record_size(bit)/4 = 每 node 字节
        let sts = node_count * node_bytes;
        self.node_count = node_count;
        self.record_size = record_size;
        self.ip_version = ip_version;
        self.pointer_base = sts - node_count;
        self.data_start = sts + 16;
        // IPv6 树：预跳 96 个 0 bit 得到 IPv4 子树根
        self.ipv4_start = if ip_version == 6 {
            let mut node = 0usize;
            for _ in 0..96 {
                if node >= node_count {
                    break;
                }
                node = self.read_record(node, 0);
                if node == 0 {
                    break;
                }
            }
            node
        } else {
            0
        };
        true
    }

    fn read_record(&self, node: usize, index: usize) -> usize {
        let rs = self.record_size / 8; // 每记录字节数
        let base = node * (rs * 2) + index * rs;
        if base + rs > self.data.len() {
            return 0;
        }
        match rs {
            3 => {
                ((self.data[base] as usize) << 16)
                    | (self.data[base + 1] as usize) << 8
                    | self.data[base + 2] as usize
            }
            4 => u32::from_le_bytes([
                self.data[base],
                self.data[base + 1],
                self.data[base + 2],
                self.data[base + 3],
            ]) as usize,
            _ => {
                let mut v = 0usize;
                for i in 0..rs {
                    v = (v << 8) | self.data[base + i] as usize;
                }
                v
            }
        }
    }

    /// 查找 IP 对应的数据段绝对偏移。None = 未命中。
    #[allow(dead_code)]
    fn lookup(&self, ip: u32) -> Option<usize> {
        let bytes = ip.to_be_bytes();
        let mut node = if self.ip_version == 6 {
            self.ipv4_start
        } else {
            0
        };
        let mut i = 0;
        let mut node_count = self.node_count;
        while i < 32 && node < node_count {
            let bit = (bytes[i >> 3] >> (7 - (i % 8))) & 1;
            let next = self.read_record(node, bit as usize);
            if next == 0 {
                return None;
            }
            node = next;
            i += 1;
            // 官方 reader：node == node_count 视为空记录
            let _ = &mut node_count;
        }
        if node <= self.node_count {
            return None;
        }
        // 官方语义：数据偏移 = node + pointer_base（node 是原始叶子值）
        Some(node + self.pointer_base)
    }

    /// 在绝对偏移处解码一个数据值，返回 (值, 下一偏移)。
    fn decode_at(&self, pos: usize, depth: u8) -> Option<(MmVal, usize)> {
        if depth > 40 || pos >= self.data.len() {
            return None;
        }
        let ctrl = self.data[pos];
        let ctype = ctrl >> 5;
        let mut size = (ctrl & 0x1f) as usize;
        let mut p = pos + 1;
        if ctype == 1 {
            // 指针：P = size 高 2 位（+1 得字节数），低 3 位是指针值高位
            let psize = (size >> 3) + 1;
            let hi = size & 7;
            if p + psize > self.data.len() {
                return None;
            }
            let mut v = 0usize;
            for i in 0..psize {
                v = (v << 8) | self.data[p + i] as usize;
            }
            v |= hi << (psize * 8);
            v += POINTER_OFFSETS[psize - 1];
            let target = v + self.data_start;
            let (val, _) = self.decode_at(target, depth + 1)?;
            return Some((val, p + psize));
        }
        if ctype == 0 {
            // 扩展类型
            let ext = *self.data.get(p)?;
            p += 1;
            (size, p) = self.read_big_size(size, p)?;
            return match ext {
                1 => {
                    // int32
                    let mut v: i64 = if size > 0 && self.data[p] & 0x80 != 0 { -1 } else { 0 };
                    for i in 0..size {
                        v = (v << 8) | self.data[p + i] as i64;
                    }
                    Some((MmVal::Uint(v as u64), p + size))
                }
                2 => {
                    // uint64
                    let mut v: u64 = 0;
                    for i in 0..size {
                        v = (v << 8) | self.data[p + i] as u64;
                    }
                    Some((MmVal::Uint(v), p + size))
                }
                4 => {
                    // array
                    let mut out = Vec::with_capacity(size.min(256));
                    let mut q = p;
                    for _ in 0..size {
                        let (v, n) = self.decode_at(q, depth + 1)?;
                        out.push(v);
                        q = n;
                    }
                    Some((MmVal::Arr(out), q))
                }
                _ => Some((MmVal::Other, p + size)),
            };
        }
        (size, p) = self.read_big_size(size, p)?;
        if p + size > self.data.len() {
            return None;
        }
        match ctype {
            2 => Some((
                MmVal::Str(String::from_utf8_lossy(&self.data[p..p + size]).to_string()),
                p + size,
            )),
            5 | 6 => {
                let mut v: u64 = 0;
                for i in 0..size {
                    v = (v << 8) | self.data[p + i] as u64;
                }
                Some((MmVal::Uint(v), p + size))
            }
            7 => {
                let mut out = Vec::with_capacity(size.min(256));
                let mut q = p;
                for _ in 0..size {
                    let (k, n) = self.decode_at(q, depth + 1)?;
                    let key = match k {
                        MmVal::Str(s) => s,
                        _ => return None,
                    };
                    let (v, n) = self.decode_at(n, depth + 1)?;
                    out.push((key, v));
                    q = n;
                }
                Some((MmVal::Map(out), q))
            }
            _ => Some((MmVal::Other, p + size)),
        }
    }

    fn read_big_size(&self, size: usize, p: usize) -> Option<(usize, usize)> {
        match size {
            29 => Some((29 + *self.data.get(p)? as usize, p + 1)),
            30 => Some((
                285 + ((*self.data.get(p)? as usize) << 8 | *self.data.get(p + 1)? as usize),
                p + 2,
            )),
            31 => Some((
                65_821
                    + ((*self.data.get(p)? as usize) << 16
                        | (*self.data.get(p + 1)? as usize) << 8
                        | *self.data.get(p + 2)? as usize),
                p + 3,
            )),
            _ => Some((size, p)),
        }
    }

    /// 展开整棵 IPv4 子树为 (start,end,data_abs_offset) 列表。
    fn expand_v4(&self) -> Vec<(u32, u32, usize)> {
        let mut out = Vec::new();
        if self.ip_version == 6 && self.ipv4_start >= self.node_count {
            // IPv4 子树整体为空
            return out;
        }
        let mut stack: Vec<(usize, u32, u8)> = vec![(self.ipv4_start, 0, 0)];
        while let Some((node, prefix, depth)) = stack.pop() {
            if node >= self.node_count || node == 0 && depth > 0 {
                if node > self.node_count {
                    let start = if depth == 0 { 0 } else { prefix << (32 - depth) };
                    let end = (start as u64 + (1u64 << (32 - depth)) - 1).min(u32::MAX as u64) as u32;
                    out.push((start, end, node + self.pointer_base));
                }
                continue;
            }
            if node == 0 && depth > 0 {
                continue;
            }
            if depth >= 32 {
                continue;
            }
            let left = self.read_record(node, 0);
            let right = self.read_record(node, 1);
            if left != 0 {
                stack.push((left, prefix << 1, depth + 1));
            }
            if right != 0 {
                stack.push((right, prefix << 1 | 1, depth + 1));
            }
        }
        out.sort_by_key(|(s, _, _)| *s);
        out
    }

    /// 从数据段绝对偏移提取 (iso_code, region, city)。
    fn extract_geo(&self, abs: usize) -> (String, String, String) {
        let Some((MmVal::Map(fields), _)) = self.decode_at(abs, 0) else {
            return (String::new(), String::new(), String::new());
        };
        let get_code = |m: &Vec<(String, MmVal)>, key: &str| -> String {
            for (k, v) in m {
                if k == key {
                    if let MmVal::Map(inner) = v {
                        for (ik, iv) in inner {
                            if ik == "iso_code" {
                                if let MmVal::Str(s) = iv {
                                    return s.clone();
                                }
                            }
                        }
                    }
                }
            }
            String::new()
        };
        let country = get_code(&fields, "country");
        let registered = get_code(&fields, "registered_country");
        let code = if country.is_empty() { registered } else { country };
        let mut region = String::new();
        let mut city = String::new();
        for (k, v) in &fields {
            if k == "subdivisions" {
                if let MmVal::Arr(arr) = v {
                    if let Some(MmVal::Map(first)) = arr.first() {
                        for (ik, iv) in first {
                            if (ik == "iso_code" || ik == "name") && region.is_empty() {
                                if let MmVal::Str(s) = iv {
                                    region = s.clone();
                                }
                            }
                        }
                    }
                }
            }
            if k == "city" {
                if let MmVal::Map(inner) = v {
                    for (ik, iv) in inner {
                        if ik == "names" {
                            if let MmVal::Map(names) = iv {
                                for (nk, nv) in names {
                                    if nk == "en" || nk == "zh-CN" {
                                        if let MmVal::Str(s) = nv {
                                            city = s.clone();
                                            if nk == "en" {
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        (code, region, city)
    }
}

fn mm_as_uint(v: &MmVal) -> u64 {
    match v {
        MmVal::Uint(u) => *u,
        _ => 0,
    }
}

fn memmem(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn parse_mmdb(data: &[u8]) -> Vec<Entry> {
    let mut entries = Vec::new();
    let mm = Mmdb {
        data,
        data_start: 0,
        pointer_base: 0,
        node_count: 0,
        record_size: 0,
        ip_version: 0,
        ipv4_start: 0,
    };
    let mut mm = mm;
    if !mm.parse_meta() {
        return entries;
    }
    let leaves = mm.expand_v4();
    for (start, end, abs) in leaves {
        let (code, region, city) = mm.extract_geo(abs);
        entries.push(Entry {
            start,
            end,
            country: code,
            region,
            city,
            isp: String::new(),
            extra: "MMDB".into(),
            lat: String::new(),
            lon: String::new(),
        });
        if entries.len() > 1_400_000 {
            break;
        }
    }
    entries.sort_by_key(|e| e.start);
    entries.dedup_by(|a, b| a.start == b.start && a.end == b.end);
    entries
}

// ---------------- 统一入口 ----------------

/// 识别并把任意支持的库文件解析为统一 Entry 列表。
pub fn parse_any(path: &str, raw: &[u8]) -> Result<Vec<Entry>, String> {
    if raw.is_empty() {
        return Err("文件为空".into());
    }
    let size = raw.len() as u64;
    let head = &raw[..raw.len().min(64)];
    let kind = detect_kind(path, head, size);
    // gz 解包（CSV.gz）
    let owned;
    let data: &[u8] = if raw.len() >= 2 && raw[0] == 0x1f && raw[1] == 0x8b {
        let mut dec = flate2::read::GzDecoder::new(raw);
        let mut out = Vec::with_capacity(raw.len() * 6);
        dec.read_to_end(&mut out).map_err(|e| format!("解压失败: {e}"))?;
        owned = out;
        &owned
    } else {
        raw
    };
    let entries = match kind {
        DbKind::Qqwry => parse_qqwry(data),
        DbKind::Xdb => parse_xdb(data),
        DbKind::Ip2Proxy => parse_ip2proxy(data),
        DbKind::Mmdb => parse_mmdb(data),
        DbKind::NetpulseTsv => parse_netpulse_tsv(&String::from_utf8_lossy(data)),
        DbKind::Csv | DbKind::Unknown => {
            let text = String::from_utf8_lossy(data);
            let v = parse_csv_text(&text);
            if v.is_empty() {
                parse_netpulse_tsv(&text)
            } else {
                v
            }
        }
    };
    if entries.is_empty() {
        return Err(format!("未能从文件解析出有效 IP 段（识别为 {kind:?}）"));
    }
    Ok(entries)
}

/// 单条查询：在已排序 entries 里二分（兼容重叠段，优先取最后一条满足区间者）。
pub fn find(entries: &[Entry], ip: u32) -> Option<&Entry> {
    if entries.is_empty() {
        return None;
    }
    let mut lo = 0usize;
    let mut hi = entries.len();
    let mut best: Option<usize> = None;
    while lo < hi {
        let mid = (lo + hi) / 2;
        let e = &entries[mid];
        if e.end < ip {
            lo = mid + 1;
        } else if e.start > ip {
            hi = mid;
        } else {
            // start <= ip <= end：记录并继续向右找更精确（更大 start）的段
            best = Some(mid);
            lo = mid + 1;
        }
    }
    best.map(|i| &entries[i])
}

/// ZIP 内成员提取（支持 ZIP.ZIP 单文件库，如 IP2Location LITE CSV.ZIP）。
pub fn unzip_first(raw: &[u8]) -> Option<Vec<u8>> {
    if raw.len() < 4 || &raw[0..2] != b"PK" {
        return None;
    }
    // 先找 EOCD；找不到则退回扫描 local file header（极简单成员 zip）。
    let eocd = raw.len().checked_sub(22).and_then(|_| {
        (0..66_000).find_map(|k| {
            let i = raw.len().checked_sub(22 + k)?;
            if &raw[i..i + 4] == b"PK\x05\x06" {
                Some(i)
            } else {
                None
            }
        })
    });
    if eocd.is_none() {
        // local header fallback
        if raw.len() > 30 && &raw[0..4] == b"PK\x03\x04" {
            let method = u16::from_le_bytes([raw[8], raw[9]]);
            let csize = u32::from_le_bytes([raw[18], raw[19], raw[20], raw[21]]) as usize;
            let name_len = u16::from_le_bytes([raw[26], raw[27]]) as usize;
            let extra_len = u16::from_le_bytes([raw[28], raw[29]]) as usize;
            let data_off = 30 + name_len + extra_len;
            if data_off + csize <= raw.len() {
                let comp = &raw[data_off..data_off + csize];
                return match method {
                    0 => Some(comp.to_vec()),
                    8 => {
                        let mut dec = flate2::read::DeflateDecoder::new(comp);
                        let mut out = Vec::with_capacity(csize * 4);
                        dec.read_to_end(&mut out).ok()?;
                        Some(out)
                    }
                    _ => None,
                };
            }
        }
        return None;
    }

    let mut eocd = None;
    let start = raw.len().saturating_sub(66_000);
    let mut i = raw.len() - 22;
    loop {
        if &raw[i..i + 4] == b"PK\x05\x06" {
            eocd = Some(i);
            break;
        }
        if i == start {
            break;
        }
        i -= 1;
    }
    let eocd = eocd?;
    let count = u16::from_le_bytes([raw[eocd + 10], raw[eocd + 11]]) as usize;
    let cd_off = u32::from_le_bytes([
        raw[eocd + 16],
        raw[eocd + 17],
        raw[eocd + 18],
        raw[eocd + 19],
    ]) as usize;
    let mut p = cd_off;
    for _ in 0..count.max(1) {
        if p + 46 > raw.len() || &raw[p..p + 4] != b"PK\x01\x02" {
            break;
        }
        let method = u16::from_le_bytes([raw[p + 10], raw[p + 11]]);
        let csize = u32::from_le_bytes([raw[p + 20], raw[p + 21], raw[p + 22], raw[p + 23]])
            as usize;
        let name_len = u16::from_le_bytes([raw[p + 28], raw[p + 29]]) as usize;
        let extra_len = u16::from_le_bytes([raw[p + 30], raw[p + 31]]) as usize;
        let comment_len = u16::from_le_bytes([raw[p + 32], raw[p + 33]]) as usize;
        let lfh_off =
            u32::from_le_bytes([raw[p + 42], raw[p + 43], raw[p + 44], raw[p + 45]]) as usize;
        let name = String::from_utf8_lossy(&raw[p + 46..p + 46 + name_len]).to_string();
        // 跳过目录与无关文件（macOS 元数据 / md5）
        let lower = name.to_ascii_lowercase();
        if !lower.ends_with('/')
            && !lower.contains("__macosx")
            && !lower.ends_with(".md5")
            && !lower.ends_with(".txt")
        {
            // 读 local file header
            if lfh_off + 30 <= raw.len() && &raw[lfh_off..lfh_off + 4] == b"PK\x03\x04" {
                let l_name = u16::from_le_bytes([raw[lfh_off + 26], raw[lfh_off + 27]]) as usize;
                let l_extra = u16::from_le_bytes([raw[lfh_off + 28], raw[lfh_off + 29]]) as usize;
                let data_off = lfh_off + 30 + l_name + l_extra;
                if data_off + csize <= raw.len() {
                    let comp = &raw[data_off..data_off + csize];
                    let out = match method {
                        0 => Some(comp.to_vec()),
                        8 => {
                            let mut dec = flate2::read::DeflateDecoder::new(comp);
                            let mut out = Vec::with_capacity(csize * 4);
                            dec.read_to_end(&mut out).ok()?;
                            Some(out)
                        }
                        _ => None,
                    };
                    if let Some(data) = out {
                        return Some(data);
                    }
                }
            }
        }
        p += 46 + name_len + extra_len + comment_len;
    }
    None
}

/// 预设下载地址（与 Flutter 侧同步维护）。
pub fn presets_json() -> Value {
    json!({
        "geolite2_city": "https://github.com/sapics/ip-location-db/releases/download/latest/geolite2-city-ipv4-num.csv.gz",
        "geolite2_country": "https://github.com/sapics/ip-location-db/releases/download/latest/geolite2-country-ipv4-num.csv",
        "dbip_city": "https://github.com/sapics/ip-location-db/releases/download/latest/dbip-city-ipv4-num.csv.gz",
        "ip2region": "https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ip2region_v4.xdb",
        "qqwry": "https://raw.githubusercontent.com/nmgliangwei/qqwry/main/qqwry.dat",
        "ip2location": "https://download.ip2location.com/lite/IP2LOCATION-LITE-DB1.CSV.ZIP",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_parsing_city() {
        let text = "16777472,16778239,CN,,,,,34.77,113.72,Asia/Shanghai\n16778240,16779263,AU,,,,,-33.49,143.21,Australia/Sydney\n";
        let e = parse_csv_text(text);
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].country, "CN");
        assert_eq!(e[0].lat, "34.77");
    }

    #[test]
    fn netpulse_tsv_roundtrip() {
        let text = "#source\tx\n#updated\t1\n#count\t2\n1\t100\tCN\t\t\t\n101\t200\tUS\tCA\tLA\tCogent\n";
        let e = parse_netpulse_tsv(text);
        assert_eq!(e.len(), 2);
        assert_eq!(e[1].region, "CA");
    }

    #[test]
    fn detect_formats() {
        let head = [0xba, 0xfa, 0xf8, 0x00, 0xf7, 0xfd, 0xa2, 0x01, 0xff, 0xff, 0xff, 0x00];
        assert_eq!(detect_kind("qqwry.dat", &head, 6_000_000), DbKind::Qqwry);
        let xdb_head = [0x03, 0x00, 0x01, 0x00, 0x75, 0x2b, 0x05, 0x6b];
        assert_eq!(detect_kind("ip2region.xdb", &xdb_head, 11_000_000), DbKind::Xdb);
        assert_eq!(detect_kind("a.mmdb", b"MaxMind.com DB", 1_000), DbKind::Mmdb);
        assert_eq!(detect_kind("a.tsv", b"1\t2\t3", 100), DbKind::NetpulseTsv);
    }

    #[test]
    fn unzip_first_finds_member() {
        // zip local header smoke: PK\x03\x04 method=0
        let mut z = Vec::new();
        z.extend_from_slice(b"PK\x03\x04");
        z.extend_from_slice(&[0, 0]); // version
        z.extend_from_slice(&[0, 0]); // flags
        z.extend_from_slice(&[0, 0]); // method = 0 (store)
        z.extend_from_slice(&[0, 0]); // time
        z.extend_from_slice(&[0, 0]); // date
        z.extend_from_slice(&[0, 0, 0, 0]); // crc32
        z.extend_from_slice(&5u32.to_le_bytes()); // csize
        z.extend_from_slice(&5u32.to_le_bytes()); // usize
        z.extend_from_slice(&[5, 0]); // name len
        z.extend_from_slice(&[0, 0]); // extra len
        z.extend_from_slice(b"a.csv");
        z.extend_from_slice(b"hello");
        assert_eq!(unzip_first(&z).unwrap(), b"hello");
    }
}
