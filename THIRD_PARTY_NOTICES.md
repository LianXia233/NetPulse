# 第三方组件与开源许可声明

<p align="left">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-007AFF?style=flat-square" alt="License: MIT"></a>
  <a href="https://db-ip.com"><img src="https://img.shields.io/badge/Data-DB--IP%20(CC%20BY%204.0)-34C759?style=flat-square" alt="DB-IP CC BY 4.0"></a>
  <a href="https://github.com/esnet/iperf"><img src="https://img.shields.io/badge/Tool-iperf3%20(BSD--3--Clause)-FF9500?style=flat-square" alt="iperf3 BSD-3-Clause"></a>
  <img src="https://img.shields.io/badge/Compliance-SPDX-AF52DE?style=flat-square" alt="SPDX Compliant">
</p>

NetPulse 自身源码基于 [MIT License](LICENSE) 开源。

为了向用户提供高性能、无缝的网络测速、动态下载与深度诊断能力，NetPulse 在随包分发、编译构建或运行时集成了若干优秀的第三方开源组件、动态库及公开数据集。本文件对上述组件的版权所有者、分发许可及官方上游进行归属声明。

---

## 目录

- [1. 核心分发组件清单](#1-核心分发组件清单)
- [2. iperf3 完整开源许可文本](#2-iperf3-完整开源许可文本)
- [3. DB-IP 数据集归属声明](#3-db-ip-数据集归属声明)
- [4. Rust 原生依赖组件库](#4-rust-原生依赖组件库)
- [5. Flutter 与 Android 系统组件](#5-flutter-与-android-系统组件)
- [6. 许可证全文索引](#6-许可证全文索引)

---

## 1. 核心分发组件清单

| 组件名称 | 分发形态 | 适用开源许可 (SPDX) | 功能与用途说明 | 上游主页 / 源码仓库 |
|:---|:---|:---:|:---|:---|
| **Flutter SDK** | 运行时引擎随包分发 | [BSD-3-Clause](https://opensource.org/licenses/BSD-3-Clause) | 前端跨平台响应式 UI 渲染管线与运行时环境 | [flutter.dev](https://flutter.dev) |
| **webview_flutter** | Flutter 插件 | [BSD-3-Clause](https://opensource.org/licenses/BSD-3-Clause) | 内置嗅探浏览器与 Android System WebView 交互通道 | [pub.dev/packages/webview_flutter](https://pub.dev/packages/webview_flutter) |
| **iperf3 (`libiperf3.so`)** | 原生预编译共享库 | [BSD-3-Clause](https://github.com/esnet/iperf/blob/master/LICENSE) | 内置网络极限打流测试引擎（ARM64 / ARMv7 双架构） | [github.com/esnet/iperf](https://github.com/esnet/iperf) |
| **Rust 标准库与运行时** | 编译进入原生库 | [MIT](https://opensource.org/licenses/MIT) / [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) | 无垃圾回收的高性能原生核心基础支撑 | [rust-lang.org](https://www.rust-lang.org) |
| **rustls** | 静态链接 Rust Crate | [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) / [ISC](https://opensource.org/licenses/ISC) | 现代轻量 TLS 1.2 / 1.3 密码学协议栈（消除 OpenSSL 依赖） | [github.com/rustls/rustls](https://github.com/rustls/rustls) |
| **webpki-roots** | 静态链接 Rust Crate | [MPL-2.0](https://www.mozilla.org/en-US/MPL/2.0/) | Mozilla 权威根证书公信锚点数据集 | [github.com/rustls/webpki-roots](https://github.com/rustls/webpki-roots) |
| **serde / serde_json** | 静态链接 Rust Crate | [MIT](https://opensource.org/licenses/MIT) / [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) | Dart 与 Rust 间 JSON-over-FFI 序列化与反序列化 | [serde.rs](https://serde.rs) |
| **aes / cbc** | 静态链接 Rust Crate | [MIT](https://opensource.org/licenses/MIT) / [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) | HLS 流媒体 AES-128 切片对称加解密支持 | [RustCrypto](https://github.com/RustCrypto) |
| **flate2** | 静态链接 Rust Crate | [MIT](https://opensource.org/licenses/MIT) / [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) | Gzip / Deflate 解压缩（IP 种子库与 HTTP 传输） | [github.com/rust-lang/flate2-rs](https://github.com/rust-lang/flate2-rs) |
| **regex** | 静态链接 Rust Crate | [MIT](https://opensource.org/licenses/MIT) / [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) | HLS M3U8 清单解析与 URL 规则提取 | [github.com/rust-lang/regex](https://github.com/rust-lang/regex) |
| **idna** | 静态链接 Rust Crate | [MIT](https://opensource.org/licenses/MIT) / [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) | 国际化域名 (IDN) Punycode 转换与 URL 标准化 | [github.com/servo/rust-url](https://github.com/servo/rust-url) |
| **DB-IP Lite** | 静态压缩种子库 (`.tsv.gz`) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | 约 43 万条国家/地区离线 IPv4 地址段归属数据 | [db-ip.com](https://db-ip.com) |

> 📌 **系统库说明**：Android System WebView 由用户终端 Android 操作系统自带并提供渲染引擎，不随本安装包分发。

---

## 2. iperf3 完整开源许可文本

NetPulse 通过预编译共享库 `libiperf3.so` 提供网络吞吐诊断能力。根据其上游许可证条款，在此完整附录其版权公告与各附属子模块许可文本：

```text
"iperf, Copyright (c) 2014-2023, The Regents of the University of California,
through Lawrence Berkeley National Laboratory (subject to receipt of any
required approvals from the U.S. Dept. of Energy).  All rights reserved."

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

(1) Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

(2) Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation and/
or other materials provided with the distribution.

(3) Neither the name of the University of California, Lawrence Berkeley
National Laboratory, U.S. Dept. of Energy nor the names of its contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

You are under no obligation whatsoever to provide any bug fixes, patches, or
upgrades to the features, functionality or performance of the source code
("Enhancements") to anyone; however, if you choose to make your Enhancements
available either publicly, or directly to Lawrence Berkeley National
Laboratory, without imposing a separate written license agreement for such
Enhancements, then you hereby grant the following license: a non-exclusive,
royalty-free perpetual license to install, use, modify, prepare derivative
works, incorporate into other computer software, distribute, and sublicense
such enhancements or derivative works thereof, in binary and source code form.

================================================================================

This software contains source code (src/cjson.{c,h}) that is:

  Copyright (c) 2009-2017 Dave Gamble and cJSON contributors

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.

================================================================================

This software contains source code (src/net.{c,h}) that is:

  This software was developed as part of a project at MIT.

  Copyright (c) 2005-2007 Russ Cox,
                     Massachusetts Institute of Technology

  Permission is hereby granted, free of charge, to any person obtaining
  a copy of this software and associated documentation files (the
  "Software"), to deal in the Software without restriction, including
  without limitation the rights to use, copy, modify, merge, publish,
  distribute, sublicense, and/or sell copies of the Software, and to
  permit persons to whom the Software is furnished to do so, subject to
  the following conditions:

  The above copyright notice and this permission notice shall be
  included in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
  LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
  OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
  WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

  Contains parts of an earlier library that has:

  /*
   * The authors of this software are Rob Pike, Sape Mullender, and Russ Cox
   *              Copyright (c) 2003 by Lucent Technologies.
   * Permission to use, copy, modify, and distribute this software for any
   * purpose without fee is hereby granted, provided that this entire notice
   * is included in all copies of any software which is or includes a copy
   * or modification of this software and in all copies of the supporting
   * documentation for such software.
   * THIS SOFTWARE IS BEING PROVIDED "AS IS", WITHOUT ANY EXPRESS OR IMPLIED
   * WARRANTY. IN PARTICULAR, NEITHER THE AUTHORS NOR LUCENT TECHNOLOGIES MAKE ANY
   * REPRESENTATION OR WARRANTY OF ANY KIND CONCERNING THE MERCHANTABILITY
   * OF THIS SOFTWARE OR ITS FITNESS FOR ANY PARTICULAR PURPOSE.
  */

================================================================================

This software contains source code (src/net.c) that is:

  Copyright (c) 2001 Eric Jackson <ericj@monkey.org>

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:

  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.
  3. The name of the author may not be used to endorse or promote products
     derived from this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
  NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

================================================================================

This software contains source code (src/queue.h) that is:

  Copyright (c) 1991, 1993
       The Regents of the University of California.  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.
  3. Neither the name of the University nor the names of its contributors
     may be used to endorse or promote products derived from this software
     without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
  SUCH DAMAGE.

================================================================================

This software contains source code (src/units.{c.h}) that is:

  Copyright (c) 1999,2000,2001,2002,2003
  The Board of Trustees of the University of Illinois
  All Rights Reserved.

  Permission is hereby granted, free of charge, to any person
  obtaining a copy of this software (Iperf) and associated
  documentation files (the "Software"), to deal in the Software
  without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute,
  sublicense, and/or sell copies of the Software, and to permit
  persons to whom the Software is furnished to do
  so, subject to the following conditions:

  Redistributions of source code must retain the above
  copyright notice, this list of conditions and
  the following disclaimers.

  Redistributions in binary form must reproduce the above
  copyright notice, this list of conditions and the following
  disclaimers in the documentation and/or other materials
  provided with the distribution.

  Neither the names of the University of Illinois, NCSA,
  nor the names of its contributors may be used to endorse
  or promote products derived from this Software without
  specific prior written permission.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
  NONINFRINGEMENT. IN NO EVENT SHALL THE CONTIBUTORS OR COPYRIGHT
  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
  ARISING FROM, OUT OF OR IN CONNECTION WITH THE
  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

================================================================================

This software contains source code (src/portable_endian.h) that is:

  License: Public Domain
  I, Mathias Panzenböck, place this file hereby into the public domain.
  Use it at your own risk for whatever you like.
```

---

## 3. DB-IP 数据集归属声明

NetPulse 内置离线 IP 归属地种子数据库来源于 [DB-IP](https://db-ip.com)，遵循 [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/) 许可协议。

依据协议要求，保留如下署名声明：

```text
IP Geolocation by DB-IP
https://db-ip.com
Licensed under Creative Commons Attribution 4.0 International License (CC BY 4.0)
```

用户在应用内更新或使用该数据衍生功能时，均受上述知识共享许可保护与约束。

---

## 4. Rust 原生依赖组件库

NetPulse 底层 `libnetpulse_core.so` 采用 Cargo 管理依赖。所有间接传递依赖（Transitive Dependencies）均遵循 Rust 社区主流宽松开源标准（双许可 MIT / Apache-2.0 或兼容协议）：

- 完整依赖图谱与确定性构建哈希以 [`core/Cargo.lock`](core/Cargo.lock) 记录为准；
- 核心网络与加密栈由 `rustls` 团队、`RustCrypto` 团队及 `Unicode-org` 维护。

---

## 5. Flutter 与 Android 系统组件

- **Flutter 运行时**：Flutter 引擎及其 Dart SDK 采用 [BSD-3-Clause](https://github.com/flutter/flutter/blob/master/LICENSE) 许可发布；
- **Material 图标与设计组件**：基于 Google Material Design 规范并遵循 Apache-2.0 许可；
- **Android Platform API**：Android 框架代码遵循 Apache-2.0 许可。

---

## 6. 许可证全文索引

如有合规审查需求，各开源许可证全文可通过以下官方权威链接查阅：

- [MIT License](https://opensource.org/licenses/MIT)
- [BSD 3-Clause "New" or "Revised" License](https://opensource.org/licenses/BSD-3-Clause)
- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
- [Mozilla Public License 2.0 (MPL-2.0)](https://www.mozilla.org/en-US/MPL/2.0/)
- [ISC License](https://opensource.org/licenses/ISC)
- [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/legalcode)

---

*免责声明：本文件旨在整理与公示 NetPulse 使用的第三方开源组件及知识产权许可，不构成正式的法律意见。*
