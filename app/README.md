# NetPulse

Flutter 客户端与 Rust core 的 Android 工程。界面、下载器、测速与网络诊断逻辑在 `lib/`，原生引擎在 `../core/`。

构建与签名说明见仓库根目录 `README.md`。本地发布签名使用 `android/key.properties` 和 keystore，二者已被 `.gitignore` 排除。
