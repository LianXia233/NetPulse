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

`accountdl` 与 `musicdl` 取自其 GitHub Release 中的 `.fxplug` 构建产物。若需要
二次分发，请先向上游作者确认授权，或用 `assets/plugins/index.json` 中的规则
替换为你自己的解析器。

解析器只拿到当前页面 URL、该站点的 Cookie、User-Agent 与 Referer；`flux.fetch`
请求由本机 Rust HTTP 栈发出，不会把 Cookie 发给请求目标之外的域名（跨域重定向
会剥离 `Cookie` / `Authorization`）。
