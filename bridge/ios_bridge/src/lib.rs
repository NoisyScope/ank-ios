// C API between the Swift app and rslib. Native code calls ak_run with protobuf
// bytes; web pages go through ak_post, which applies desktop's access rules.
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::OnceLock;

use anki::backend::{init_backend, Backend};
use anki_proto::backend::{BackendError, BackendInit};
use prost::Message;

mod methods;
use methods::{EXPOSED, METHODS};

/// Same whitelist desktop applies to reviewer pages in mediasrv.py, which run
/// third-party card JS. getSchedulingStatesWithContext and setSchedulingStates
/// are Python handlers on desktop and are not implemented here yet.
const REVIEWER_ALLOWED: &[&str] = &["i18nResources", "congratsInfo"];

const OK: i32 = 0;
const BACKEND_ERROR: i32 = 1;
const BRIDGE_ERROR: i32 = 2;

static BE: OnceLock<Backend> = OnceLock::new();

fn give(bytes: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let mut b = bytes.into_boxed_slice();
    unsafe {
        *out_len = b.len();
        *out = b.as_mut_ptr();
    }
    std::mem::forget(b);
}

fn cstr(p: *const c_char) -> String {
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn slice<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p, len) } }
}

/// Runs a backend method by snake_case name. Err holds encoded BackendError bytes.
fn run(name: &str, input: &[u8]) -> Result<Vec<u8>, (i32, Vec<u8>)> {
    let be = BE.get().ok_or((BRIDGE_ERROR, b"backend not started".to_vec()))?;
    let &(_, s, m) = METHODS.iter().find(|x| x.0 == name)
        .ok_or_else(|| (BRIDGE_ERROR, format!("no method {name}").into_bytes()))?;
    catch_unwind(AssertUnwindSafe(|| be.run_service_method(s, m, input)))
        .unwrap_or_else(|_| Err(Vec::new()))
        .map_err(|v| if v.is_empty() { (BRIDGE_ERROR, b"panic".to_vec()) } else { (BACKEND_ERROR, v) })
}

#[no_mangle]
pub extern "C" fn ak_start(lang: *const c_char) -> bool {
    let init = BackendInit { preferred_langs: vec![cstr(lang)], ..Default::default() };
    BE.get().is_some() || init_backend(&init.encode_to_vec()).map(|b| BE.set(b).is_ok()).unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn ak_run(
    name: *const c_char, input: *const u8, len: usize, out: *mut *mut u8, out_len: *mut usize,
) -> i32 {
    match run(&cstr(name), slice(input, len)) {
        Ok(b) => { give(b, out, out_len); OK }
        Err((code, b)) => { give(b, out, out_len); code }
    }
}

/// Raw SQL through the same proxy desktop uses; takes and returns JSON.
#[no_mangle]
pub extern "C" fn ak_db(input: *const u8, len: usize, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    let Some(be) = BE.get() else { return BRIDGE_ERROR };
    match catch_unwind(AssertUnwindSafe(|| be.run_db_command_bytes(slice(input, len)))) {
        Ok(Ok(b)) => { give(b, out, out_len); OK }
        Ok(Err(b)) => { give(b, out, out_len); BACKEND_ERROR }
        Err(_) => BRIDGE_ERROR,
    }
}

/// Serves a page's POST /_anki/<camelName> and returns an HTTP status.
/// `restricted` marks reviewer pages, which may run third-party card JS.
#[no_mangle]
pub extern "C" fn ak_post(
    name: *const c_char, restricted: bool, input: *const u8, len: usize,
    out: *mut *mut u8, out_len: *mut usize,
) -> i32 {
    let name = cstr(name);
    let n = name.as_str();
    if !(REVIEWER_ALLOWED.contains(&n) || (!restricted && EXPOSED.contains(&n))) {
        give(b"forbidden".to_vec(), out, out_len);
        return 403;
    }
    let snake: String = n.chars().flat_map(|c| {
        if c.is_ascii_uppercase() { vec!['_', c.to_ascii_lowercase()] } else { vec![c] }
    }).collect();
    match run(&snake, slice(input, len)) {
        Ok(b) => { give(b, out, out_len); 200 }
        Err((code, b)) => {
            let msg = if code == BACKEND_ERROR {
                BackendError::decode(&*b).map(|e| e.message.into_bytes()).unwrap_or(b)
            } else { b };
            give(msg, out, out_len);
            500
        }
    }
}

#[no_mangle]
pub extern "C" fn ak_free_buf(p: *mut u8, len: usize) {
    if !p.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len))) }
    }
}
