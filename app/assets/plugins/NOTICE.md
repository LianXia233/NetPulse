# 内置站点解析器说明

`assets/plugins/` 下的解析器来自以下公开仓库，版权归各作者所有。NetPulse 只做
站点解析器 manifest / resolve.js 兼容运行，不修改解析逻辑。

| 目录 | 上游仓库 | 许可证 |
|:---|:---|:---|
| `m3u8-pro` | https://github.com/Ouyangyouzi/fluxdown-m3u8-pro | MIT（见同目录 LICENSE） |
| `github-accel` | https://github.com/zerx-lab/fluxdown-plugin-github-accel | 上游未声明 |
| `quark-share` | https://github.com/myderr/fluxdown-quark-share | 上游未声明 |
| `accountdl` | https://github.com/zerx-lab/fluxdown-plugin-accountdl | 上游未声明 |
| `musicdl` | https://github.com/zerx-lab/fluxdown-plugin-musicdl | 上游未声明 |
| `bilibili` | https://github.com/gulanthys/fluxdown-bilibili-bangumi | 上游未声明 |
| `anime-sites` | 本项目自研 | 随项目 LICENSE |
| `linkswift` | https://github.com/hmjz100/LinkSwift | AGPL-3.0-or-later |

`accountdl` 与 `musicdl` 取自其 GitHub Release 中的 `.fxplug` 构建产物。若需要
二次分发，请先向上游作者确认授权，或用 `assets/plugins/index.json` 中的规则
替换为你自己的解析器。

`linkswift/` 逐字包含 LinkSwift 的用户脚本主体（`linkswift.js`），仅在外层加了
依赖注入包装，使其在 NetPulse 内置浏览器内直接运行；配套的 Greasemonkey 兼容层
（`gm-shim.js`）、下载桥（`netpulse-bridge.js`）与本项目其余代码同样按
AGPL-3.0-or-later 分发。`vendor/` 下的 jQuery（MIT）、SweetAlert2（MIT）、
js-md5（MIT）、js-sha256（MIT）版权归各自作者。

解析器只拿到当前页面 URL、该站点的 Cookie、User-Agent 与 Referer；`flux.fetch`
请求由本机 Rust HTTP 栈发出，不会把 Cookie 发给请求目标之外的域名（跨域重定向
会剥离 `Cookie` / `Authorization`）。
