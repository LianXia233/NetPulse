/*
 * LinkSwift 页面增强插件的解析入口。
 *
 * 真正的直链解析发生在页面内（linkswift.js），结果由 netpulse-bridge.js
 * 通过 `netpulse.direct()` 直接交给下载器。这里不参与资源地址匹配，
 * 只在宿主误调用时安全返回，避免把网盘分享页当成可解析资源。
 */
globalThis.resolve = function () {
  return null;
};
