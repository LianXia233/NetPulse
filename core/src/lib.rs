//! NetPulse · Rust core (FFI 入口)
//!
//! 设计：单个 `np_call(json)` 入口 + 任务轮询模型。
//! Dart 侧用一个 DynamicLibrary 打开 libnetpulse_core.so，发送 JSON 命令。

mod diag;
mod dns;
mod download;
mod http;
pub mod ipdb;
pub mod ipgeo;
mod speed;
mod webfetch;

use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

pub struct Task {
    pub kind: String,
    pub cancel: Arc<AtomicBool>,
    pub events: Arc<Mutex<Vec<Value>>>,
    pub status: Arc<Mutex<String>>,
    pub summary: Arc<Mutex<Option<Value>>>,
}

impl Task {
    pub fn emit(&self, v: Value) {
        let mut ev = self.events.lock().unwrap();
        if ev.len() < 4000 {
            ev.push(v);
        }
    }

    pub fn finish(&self, status: &str, summary: Value) {
        *self.summary.lock().unwrap() = Some(summary);
        *self.status.lock().unwrap() = status.to_string();
    }

    pub fn set_status(&self, status: &str) {
        *self.status.lock().unwrap() = status.to_string();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }
}

static TASKS: OnceLock<Mutex<HashMap<String, Arc<Task>>>> = OnceLock::new();
static SEQ: AtomicU64 = AtomicU64::new(1);

pub fn tasks() -> &'static Mutex<HashMap<String, Arc<Task>>> {
    TASKS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn new_task(kind: &str) -> (String, Arc<Task>) {
    let id = format!("t{}", SEQ.fetch_add(1, Ordering::SeqCst));
    let task = Arc::new(Task {
        kind: kind.to_string(),
        cancel: Arc::new(AtomicBool::new(false)),
        events: Arc::new(Mutex::new(Vec::new())),
        status: Arc::new(Mutex::new("running".to_string())),
        summary: Arc::new(Mutex::new(None)),
    });
    tasks().lock().unwrap().insert(id.clone(), task.clone());
    (id, task)
}

/// 后台任务统一入口：任何 panic 都转成任务错误，而不是让整个进程 abort。
pub fn spawn_task<F>(task: Arc<Task>, f: F)
where
    F: FnOnce(Arc<Task>) + Send + 'static,
{
    std::thread::spawn(move || {
        let runner = task.clone();
        let failed = catch_unwind(AssertUnwindSafe(|| f(runner))).is_err();
        if failed {
            task.emit(json!({"type": "error", "message": "core panic"}));
            task.finish("error", json!({"error": "core panic"}));
        }
    });
}

pub fn get_task(id: &str) -> Result<Arc<Task>, String> {
    tasks()
        .lock()
        .unwrap()
        .get(id)
        .cloned()
        .ok_or_else(|| "任务不存在".to_string())
}

fn handle(cmd: &str, args: &Value) -> Result<Value, String> {
    match cmd {
        "ping" => Ok(json!({"pong": true})),
        "version" => Ok(json!({
            "core": env!("CARGO_PKG_VERSION"),
            "engine": "netpulse-core-rust",
            "features": ["multi_cdn", "multi_dns", "download", "upload", "dns", "ping", "nat", "trace", "iperf", "web_fetch"]
        })),
        "start_speed" => speed::start(args.clone()),
        "start_download" => download::add(args.clone()),
        "resource_links" => download::resolve_resource_links(args),
        "dl_list" => Ok(download::list()),
        "dl_scan" => Ok(download::scan(args)),
        "dl_stat" => Ok(download::stat(args)),
        "dl_detail" => download::detail(args),
        "dl_delete" => download::delete(args),
        "start_dns" => diag::start_dns(args.clone()),
        "start_ping" => diag::start_ping(args.clone()),
        "start_nat" => diag::start_nat(args.clone()),
        "start_trace" => diag::start_trace(args.clone()),
        "start_iperf" => diag::start_iperf(args.clone()),
        "web_fetch" => webfetch::fetch(args),
        "ipdb_update" => ipgeo::update(args),
        "ipdb_info" => ipgeo::info(args),
        "ipdb_lookup" => ipgeo::lookup(args),
        "ipdb_lookup_many" => ipgeo::lookup_many(args),
        "ipdb_egress" => ipgeo::egress(args),
        "dns_resolve" => ipgeo::resolve_host(args),
        "ip_geo_auto" => ipgeo::api_auto(args),
        "ip_geo_auto_batch" => ipgeo::api_auto_batch(args),
        "ip_type" => ipgeo::ip_type(args),
        "ip_api" => ipgeo::api(args),
        "task_poll" => {
            let id = args["id"].as_str().ok_or("缺少任务 id")?;
            let task = get_task(id)?;
            let mut ev = task.events.lock().unwrap();
            let events: Vec<Value> = ev.drain(..).collect();
            drop(ev);
            Ok(json!({
                "id": id,
                "kind": task.kind,
                "status": *task.status.lock().unwrap(),
                "events": events,
                "summary": *task.summary.lock().unwrap(),
            }))
        }
        "task_cancel" => {
            let id = args["id"].as_str().ok_or("缺少任务 id")?;
            let task = get_task(id)?;
            let finished = matches!(
                task.status.lock().unwrap().as_str(),
                "done" | "error" | "cancelled" | "paused"
            );
            if !finished {
                task.cancel.store(true, Ordering::Relaxed);
                task.set_status("cancelling");
            }
            Ok(json!({"id": id}))
        }
        "task_dispose" => {
            let id = args["id"].as_str().ok_or("缺少任务 id")?;
            tasks().lock().unwrap().remove(id);
            Ok(json!({"id": id}))
        }
        other => Err(format!("未知命令: {}", other)),
    }
}

fn dispatch(raw: &str) -> String {
    let parsed: Result<Value, _> = serde_json::from_str(raw);
    let v = match parsed {
        Ok(v) => v,
        Err(e) => {
            return json!({"ok": false, "error": format!("JSON 解析失败: {}", e)}).to_string()
        }
    };
    let cmd = v["cmd"].as_str().unwrap_or("");
    let args = v.get("args").cloned().unwrap_or_else(|| json!({}));
    match handle(cmd, &args) {
        Ok(data) => json!({"ok": true, "data": data}).to_string(),
        Err(e) => json!({"ok": false, "error": e}).to_string(),
    }
}

/// # Safety
/// `req` 必须是有效的、以 NUL 结尾的 C 字符串指针，或为空指针。
#[no_mangle]
pub unsafe extern "C" fn np_call(req: *const c_char) -> *mut c_char {
    let raw = if req.is_null() {
        String::new()
    } else {
        CStr::from_ptr(req).to_string_lossy().to_string()
    };
    let out = std::panic::catch_unwind(|| dispatch(&raw))
        .unwrap_or_else(|_| json!({"ok": false, "error": "core panic"}).to_string());
    CString::new(out.replace('\u{0}', ""))
        .unwrap_or_else(|_| CString::new("{\"ok\":false}").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn np_version() -> *mut c_char {
    CString::new("netpulse-core 0.1.0").unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn np_alloc(len: u32) -> *mut u8 {
    unsafe { libc::malloc(len as usize) as *mut u8 }
}

/// # Safety
/// `ptr` 必须来自 `np_alloc`，且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn np_dealloc(ptr: *mut u8) {
    if !ptr.is_null() {
        libc::free(ptr as *mut libc::c_void);
    }
}

/// # Safety
/// `ptr` 必须来自 `np_call`/`np_version` 的返回值，且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn np_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
