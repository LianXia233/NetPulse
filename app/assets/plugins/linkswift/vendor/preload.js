/*
 * 依赖加载前置：记录页面原有的全局引用。
 *
 * 这一批执行顺序是 preload → jQuery → SweetAlert2 → md5 → sha256 → gm-shim，
 * 依赖库会临时挂到 window 上，gm-shim 取到引用后立刻还原，
 * 页面自己的 jQuery 不会被顶掉。
 */
(function () {
  'use strict';
  window.__npPrev = {
    dollar: window.$,
    jq: window.jQuery,
    Swal: window.Swal,
    md5: window.md5,
    sha256: window.sha256,
  };
})();
