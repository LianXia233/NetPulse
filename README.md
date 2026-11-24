# NetPulse

独立的 Flutter + Rust 网络工具：多 CDN / 多 DNS 测速、动态分段下载、内置浏览器与网络诊断。所有网络能力在本机 Rust 引擎执行，不依赖外部服务。

## 功能

- **下载测速**：多 CDN 端点、多 DNS 解析、多线程并发、随机 Range、250 ms 采样，输出稳态与峰值。
- **上传测速**：端点与线程可配置。
- **分段下载**：动态分块队列、连接数可调、断点续传、失败重试；支持多 CDN 镜像与完整请求头透传（Cookie / Referer / Authorization / 自定义头）。
- **内置浏览器**：打开网页、嗅探页面直链，把链接连同鉴权参数推送到下载器；支持系统分享与外部链接直接唤起下载参数页。
- **IP 归属地**：内置 36 万条国家/地区段（开箱带国旗），支持 CSV / CSV.GZ 一键更新；同时可配置 IP API，展示国家、地区、城市、ISP、ASN、坐标与时区等完整字段。
- **诊断**：TCP Ping、DNS A/AAAA 多服务器对照、STUN NAT、路由追踪、iperf3。
- **测速引擎**：Rust 多线程、多 CDN 轮换、失败自动换源与退避；采样做指数平滑并剔除启动爬升，结果以稳定速率呈现；停止立即进入「停止中」并在秒级汇总。
- **界面**：超椭圆卡片、渐变表盘、平滑面积图、药丸分段控件、页面转场与按压反馈；浅色/深色/纯黑、八色主题。

## 下载参数模型

`start_download` 支持逐任务覆盖：

| 参数 | 说明 |
|---|---|
| `url` | 主下载地址，查询串与签名原样保留 |
| `mirrors` | 同一文件的多 CDN 镜像，分段轮询接管 |
| `headers` | UA、Referer、Cookie、Authorization 及任意自定义头 |
| `dns_servers` | 该任务使用的 DNS 列表 |
| `connections` | 并发连接数 1–32 |
| `block_kb` | 分块大小 64 KB–8 MB |
| `retries` | 单分块失败重试次数 0–10 |

参数会写入续传元数据，暂停后恢复时原样复用。保存目录可在设置中修改，也可在每次推送时单独指定。

## 链接推送

- 应用内浏览器：`NavigationDelegate` 拦截可下载链接，读取 `document.cookie`、`navigator.userAgent` 与当前页 Referer，填入下载参数弹层。
- 系统分享 / 外部打开：`ACTION_SEND`（text/plain）与 `ACTION_VIEW`（http/https）进入应用后直接打开下载参数弹层。
- 手动粘贴：下载页「新建下载」，同样展示完整高级参数。

## 目录

```
app/     Flutter UI
  lib/theme.dart            设计 token 与主题
  lib/widgets.dart          卡片 / 表盘 / 图表 / 表单
  lib/bridge.dart           FFI 与原生通道
  lib/download_sheet.dart   链接推送与下载参数弹层
  lib/pages/browser_page.dart
core/    Rust 引擎（DNS / HTTP / 测速 / 下载 / 诊断）
docs/    架构说明
tools/   构建脚本
```

## 构建

```bash
# Rust（Android）
export NDK=$ANDROID_HOME/ndk/27.3.13750724
export TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
export CC_aarch64_linux_android=$TC/aarch64-linux-android24-clang
export AR_aarch64_linux_android=$TC/llvm-ar
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$TC/aarch64-linux-android24-clang
export RUSTFLAGS="-Clink-arg=-Wl,-z,max-page-size=16384"
cargo build --release --target aarch64-linux-android
cargo build --release --target armv7-linux-androideabi

# APK
cd ../app
flutter build apk --release \
  --target-platform android-arm64 --target-platform android-arm
```

或直接执行 `tools/build.sh`。`ANDROID_HOME` 未设置时脚本会尝试 `$HOME/toolchain/android/sdk`。

## 说明

- 包名 `com.netpulse.app`；发布签名使用本地 `app/android/key.properties` 与 keystore，均不纳入版本控制。
- 浏览器使用系统 WebView；下载参数仅保存在本机。
- 目前不含 VPN 分流、悬浮窗与双卡绑定等系统级能力。
- 内置 IP 国家/地区数据来自 DB-IP（CC BY 4.0），可在应用内替换为更新版本。
