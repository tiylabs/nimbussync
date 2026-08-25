//! Deliberately narrow C ABI. Swift receives opaque, versioned primitives and
//! does not own a Rust runtime, trait object, URL or filesystem path.

use cloudreve_core::CORE_API_VERSION;
use cloudreve_protocol::validate_local_identifier;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

#[no_mangle]
pub extern "C" fn cloudreve_core_abi_version() -> u32 { CORE_API_VERSION }

#[no_mangle]
pub extern "C" fn cloudreve_validate_local_identifier(value: *const c_char, prefix: *const c_char) -> c_int {
    if value.is_null() || prefix.is_null() { return 0; }
    let value = unsafe { CStr::from_ptr(value) }.to_str().ok();
    let prefix = unsafe { CStr::from_ptr(prefix) }.to_str().ok();
    match (value, prefix) {
        (Some(value), Some(prefix)) if validate_local_identifier(value, prefix).is_ok() => 1,
        _ => 0,
    }
}

