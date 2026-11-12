// Tests/CLI/Driver/incremental_iface_pch_failed.k: kz_dup with one type.
ffi "c" fn kz_dup(x: i32) -> i32 { return x + 1 }

pub fn fa(v: i32) -> i32 {
    return kz_dup(v)
}
