// Tests/CLI/Driver/incremental_iface_pch_failed.k: kz_dup with another,
// declared and never called. Alone this TU is fine; beside ma.k's in the
// interface PCH's one stream it is a conflict.
ffi "c" fn kz_dup(x: f64) -> f64

pub fn fb(v: i32) -> i32 {
    return v * 2
}
