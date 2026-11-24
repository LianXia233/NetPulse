//! 多格式本地库端到端验证（用 testdata 里的真实数据库文件跑一遍）。
//! 用法: cargo test --test e2e_ipdb -- --nocapture

use netpulse_core::ipdb;

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata");

fn load(name: &str) -> Vec<ipdb::Entry> {
    let path = format!("{DIR}/{name}");
    let Ok(raw) = std::fs::read(&path) else {
        // testdata/ 不入库（含数十 MB 数据库文件）；本地放置后即可跑端到端验证。
        println!("skip {name}: testdata/{name} not present");
        return Vec::new();
    };
    let entries = ipdb::parse_any(name, &raw).unwrap_or_else(|e| panic!("parse {name}: {e}"));
    println!(
        "{name}: {} entries, kind={:?}",
        entries.len(),
        ipdb::detect_kind(name, &raw[..raw.len().min(64)], raw.len() as u64)
    );
    entries
}

fn q(entries: &[ipdb::Entry], ip: &str) -> String {
    let n = ipdb::ipv4(ip).unwrap();
    match ipdb::find(entries, n) {
        Some(e) => format!(
            "{} => country={} region={} city={} isp={} extra={}",
            ip, e.country, e.region, e.city, e.isp, e.extra
        ),
        None => format!("{ip} => MISS"),
    }
}

#[test]
fn e2e_all_formats() {
    // 1) 纯真
    let qqwry = load("qqwry.dat");
    for ip in ["114.114.114.114", "223.5.5.5", "202.96.134.133", "8.8.8.8"] {
        println!("  {}", q(&qqwry, ip));
    }
    if !qqwry.is_empty() {
        assert!(qqwry
            .iter()
            .take(50_000)
            .any(|e| e.country.contains("中国") || e.region.contains("省") || !e.isp.is_empty()));
    }

    // 2) ip2region
    let xdb = load("ip2region.xdb");
    for ip in ["223.5.5.5", "114.114.114.114", "8.8.8.8", "39.156.66.10"] {
        println!("  {}", q(&xdb, ip));
    }
    if !xdb.is_empty() {
        let hit = ipdb::ipv4("223.5.5.5").and_then(|n| ipdb::find(&xdb, n));
        assert!(hit.unwrap().country.contains("中国"));
    }

    // 3) IP2Proxy LITE PX4 (gz 解包后是 BIN)
    let Ok(raw) = std::fs::read(format!("{DIR}/IP2PROXY-LITE-PX4.BIN.gz")) else {
        println!("skip px4");
        return;
    };
    let mut dec = flate2::read::GzDecoder::new(&raw[..]);
    let mut bin = Vec::new();
    std::io::Read::read_to_end(&mut dec, &mut bin).unwrap();
    let px = ipdb::parse_any("IP2PROXY-LITE-PX4.BIN", &bin).expect("parse px4");
    println!("IP2PROXY-LITE-PX4.BIN: {} entries", px.len());
    for ip in ["8.8.8.8", "103.75.190.1", "1.15.232.62"] {
        println!("  {}", q(&px, ip));
    }
    // 8.8.8.8 是 Google DNS 数据中心 → PX4 标记 DCH
    let hit = ipdb::ipv4("8.8.8.8").and_then(|n| ipdb::find(&px, n));
    assert_eq!(hit.unwrap().extra, "DCH");

    // 4) GeoLite2-Country MMDB
    let mmdb = load("GeoLite2-Country.mmdb");
    if mmdb.is_empty() {
        println!("其余格式样例缺失，跳过");
        return;
    }
    for ip in ["8.8.8.8", "114.114.114.114", "223.5.5.5", "43.134.66.1", "1.1.1.1"] {
        println!("  {}", q(&mmdb, ip));
    }
    let hit = ipdb::ipv4("8.8.8.8").and_then(|n| ipdb::find(&mmdb, n));
    assert_eq!(hit.unwrap().country, "US");
    let hit = ipdb::ipv4("223.5.5.5").and_then(|n| ipdb::find(&mmdb, n));
    assert_eq!(hit.unwrap().country, "CN");

    // 5) GeoLite2-City CSV.gz
    let Ok(raw) = std::fs::read(format!("{DIR}/geolite2-city-ipv4-num.csv.gz")) else {
        println!("skip city");
        return;
    };
    let mut dec = flate2::read::GzDecoder::new(&raw[..]);
    let mut csv = Vec::new();
    std::io::Read::read_to_end(&mut dec, &mut csv).unwrap();
    let city = ipdb::parse_any("geolite2-city-ipv4-num.csv", &csv).expect("parse city");
    println!("geolite2-city: {} entries", city.len());
    for ip in ["8.8.8.8", "223.5.5.5", "114.114.114.114"] {
        println!("  {}", q(&city, ip));
    }

    // 6) IP2Location LITE DB1 (ZIP)
    let Ok(raw) = std::fs::read(format!("{DIR}/IP2LOCATION-LITE-DB1.CSV.ZIP")) else {
        println!("skip db1");
        return;
    };
    let inner = ipdb::unzip_first(&raw).expect("unzip");
    let db1 = ipdb::parse_any("IP2LOCATION-LITE-DB1.CSV", &inner).expect("parse db1");
    println!("IP2LOCATION-LITE-DB1: {} entries", db1.len());
    for ip in ["8.8.8.8", "223.5.5.5"] {
        println!("  {}", q(&db1, ip));
    }
    let hit = ipdb::ipv4("8.8.8.8").and_then(|n| ipdb::find(&db1, n));
    assert_eq!(hit.unwrap().country, "US");
}
