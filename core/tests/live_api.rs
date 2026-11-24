//! 在线 IP API normalize 验证（proxycheck.io / ipapi.is / IP.SB）。

use netpulse_core::ipgeo;

#[test]
#[ignore]
fn live_new_apis() {
    for url in [
        "https://proxycheck.io/v2/8.8.8.8?vpn=1&asn=1&risk=1",
        "https://api.ipapi.is/?q=8.8.8.8",
        "https://api.ip.sb/geoip/8.8.8.8",
        "https://ipwho.is/8.8.8.8",
    ] {
        let args = serde_json::json!({"ip": "8.8.8.8", "endpoint": url});
        match ipgeo::api(&args) {
            Ok(v) => {
                let data = &v["data"];
                println!(
                    "{}\n  => country={:?} cc={:?} isp={:?} as={:?} type={:?}\n",
                    url,
                    data["country"].as_str().unwrap_or(""),
                    data["countryCode"].as_str().unwrap_or(""),
                    data["isp"].as_str().unwrap_or(""),
                    data["as"].as_str().unwrap_or(""),
                    data["proxy_type"].as_str().unwrap_or(""),
                );
                assert_eq!(
                    data["status"].as_str(),
                    Some("success"),
                    "{url} should normalize to success"
                );
                assert_eq!(data["countryCode"].as_str(), Some("US"), "{url} cc");
            }
            Err(e) => panic!("{url} failed: {e}"),
        }
    }
}
