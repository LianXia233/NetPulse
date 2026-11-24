# 第三方组件与许可

NetPulse 自身源码以 [MIT License](LICENSE) 发布。本文件列出随 APK 分发、运行时依赖或数据来源中的主要第三方组件；各组件的版权与许可归其原作者所有。

## 组件清单

| 组件 | 用途 | 许可 | 上游 |
|---|---|---|---|
| Flutter / Dart | UI 框架与运行时 | BSD-3-Clause | https://flutter.dev |
| webview_flutter | WebView 插件 | BSD-3-Clause | https://pub.dev/packages/webview_flutter |
| Rust / serde / serde_json | 核心运行时与 JSON 桥 | MIT / Apache-2.0 | https://www.rust-lang.org |
| rustls / webpki-roots | TLS 与根证书 | Apache-2.0 / ISC / MPL-2.0 | https://github.com/rustls/rustls |
| AES / CBC / regex 等 Rust crate | HLS AES-128 解密与清单解析 | MIT / Apache-2.0 | https://crates.io |
| iperf3 | 内置网络打流 | BSD-3-Clause | https://github.com/esnet/iperf |
| Android System WebView | 内置浏览器渲染内核 | Apache-2.0 | https://developer.android.com/guide/webapps |
| DB-IP | 内置 IP 归属地数据 | CC BY 4.0 | https://db-ip.com |

> Android System WebView 由 Android 系统提供，不随 APK 打包。Flutter 引擎、Rust 依赖和 `libiperf3.so` 会随 APK 分发。

## iperf3

本项目通过预编译的 `libiperf3.so`（arm64-v8a / armeabi-v7a）随包提供 iperf3 能力。以下为 iperf3 上游 LICENSE 的完整文本：

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
Enhancements, then you hereby grant the following license: a  non-exclusive,
royalty-free perpetual license to install, use, modify, prepare derivative
works, incorporate into other computer software, distribute, and sublicense
such enhancements or derivative works thereof, in binary and source code form.

=====

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

=====

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

  ===

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
   * WARRANTY.  IN PARTICULAR, NEITHER THE AUTHORS NOR LUCENT TECHNOLOGIES MAKE ANY
   * REPRESENTATION OR WARRANTY OF ANY KIND CONCERNING THE MERCHANTABILITY
   * OF THIS SOFTWARE OR ITS FITNESS FOR ANY PARTICULAR PURPOSE.
  */

=====

This software contains source code (src/net.c) that is:

/*
 * Copyright (c) 2001 Eric Jackson <ericj@monkey.org>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

=====

This software contains source code (src/queue.h) that is:

  /*
   * Copyright (c) 1991, 1993
   *      The Regents of the University of California.  All rights reserved.
   *
   * Redistribution and use in source and binary forms, with or without
   * modification, are permitted provided that the following conditions
   * are met:
   * 1. Redistributions of source code must retain the above copyright
   *    notice, this list of conditions and the following disclaimer.
   * 2. Redistributions in binary form must reproduce the above copyright
   *    notice, this list of conditions and the following disclaimer in the
   *    documentation and/or other materials provided with the distribution.
   * 3. Neither the name of the University nor the names of its contributors
   *    may be used to endorse or promote products derived from this software
   *    without specific prior written permission.
   *
   * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
   * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
   * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
   * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
   * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
   * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
   * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
   * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
   * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
   * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
   * SUCH DAMAGE.
   *
   *      @(#)queue.h     8.5 (Berkeley) 8/20/94
   */

=====

This software contains source code (src/units.{c.h}) that is:

  /*---------------------------------------------------------------
   * Copyright (c) 1999,2000,2001,2002,2003
   * The Board of Trustees of the University of Illinois
   * All Rights Reserved.
   *---------------------------------------------------------------
   * Permission is hereby granted, free of charge, to any person
   * obtaining a copy of this software (Iperf) and associated
   * documentation files (the "Software"), to deal in the Software
   * without restriction, including without limitation the
   * rights to use, copy, modify, merge, publish, distribute,
   * sublicense, and/or sell copies of the Software, and to permit
   * persons to whom the Software is furnished to do
   * so, subject to the following conditions:
   *
   *
   * Redistributions of source code must retain the above
   * copyright notice, this list of conditions and
   * the following disclaimers.
   *
   *
   * Redistributions in binary form must reproduce the above
   * copyright notice, this list of conditions and the following
   * disclaimers in the documentation and/or other materials
   * provided with the distribution.
   *
   *
   * Neither the names of the University of Illinois, NCSA,
   * nor the names of its contributors may be used to endorse
   * or promote products derived from this Software without
   * specific prior written permission.
   *
   * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
   * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
   * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
   * NONINFRINGEMENT. IN NO EVENT SHALL THE CONTIBUTORS OR COPYRIGHT
   * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
   * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
   * ARISING FROM, OUT OF OR IN CONNECTION WITH THE
   * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
   * ________________________________________________________________
   * National Laboratory for Applied Network Research
   * National Center for Supercomputing Applications
   * University of Illinois at Urbana-Champaign
   * http://www.ncsa.uiuc.edu
   * ________________________________________________________________
   *
   * stdio.c
   * by Mark Gates <mgates@nlanr.net>
   * and Ajay Tirumalla <tirumala@ncsa.uiuc.edu>
   * -------------------------------------------------------------------
   * input and output numbers, converting with kilo, mega, giga
   * ------------------------------------------------------------------- */

=====

This software contains source code (src/portable_endian.h) that is:

// "License": Public Domain
// I, Mathias Panzenböck, place this file hereby into the public domain. Use it at your own risk for whatever you like.

=====
```

## DB-IP

内置 IP 归属地数据来自 DB-IP，许可为 Creative Commons Attribution 4.0 International（CC BY 4.0）。使用或再分发时应保留以下 attribution：

```text
IP Geolocation by DB-IP
https://db-ip.com
Licensed under CC BY 4.0
```

## 其他说明

- Flutter 及其内置引擎的 BSD-3-Clause 文本见 Flutter SDK 中的 `LICENSE`。
- Rust crates 的具体版本与许可以 `core/Cargo.lock` 及各 crate 上游为准。
- 本文件仅用于整理主要第三方许可信息，不构成法律意见。
