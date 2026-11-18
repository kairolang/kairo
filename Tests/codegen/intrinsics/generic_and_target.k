// An intrinsic forwarded through a generic, and __builtin_target_info on a
// musl target (the driver's __kairo_env_musl__ macro). Named explicitly: the
// default target follows the host's C library, glibc on most Linux hosts.
fn <T> g(v: T) -> u32 { return __builtin_popcount(v) }

fn main() -> i32 {
    eval ti = __builtin_target_info()
    if !ti.is_musl() { return 1 }
    return g(7u8) as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, host-x86_64, host-linux, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
