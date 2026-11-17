// The bit intrinsics (`__builtin_ctz`, `__builtin_clz`, `__builtin_popcount`,
// `__builtin_bswap`, `__builtin_rotl`, `__builtin_rotr`) read nothing but
// their argument, so a `@pure` function and a `const fn` may call them.
// `__builtin_copy` writes through its destination: a `@pure` function may
// call it when the destination is the address of its own local (the write
// is to storage no caller sees); any other destination, and any call in a
// `const` function (it reads memory through its source), is SC200E.

@pure
fn tz(m: u32) -> u32 {
    return __builtin_ctz(m) + __builtin_clz(m) + __builtin_popcount(m)
}

fn sw(m: u32) const -> u32 {
    return __builtin_bswap(m) + __builtin_rotl(m, 3) + __builtin_rotr(m, 3)
}

@pure
fn load(p: unsafe *const u8) -> u64 {
    var w: u64 = 0
    unsafe { __builtin_copy(&w as unsafe *u8, p, 8) }
    return w
}

@pure
fn load_arr(p: unsafe *const u8) -> u8 {
    var b: [u8; 4] = [0, 0, 0, 0]
    unsafe { __builtin_copy(&b[0] as unsafe *u8, p, 4) }
    return b[1]
}

@pure
fn store(d: unsafe *u8, p: unsafe *const u8) -> u8 {
    unsafe { __builtin_copy(d, p, 1) }
    return 0
}

fn main() -> i32 {
    var b: [u8; 8] = [1, 0, 0, 0, 0, 0, 0, 0]
    var t = tz(8) + sw(0)
    var w = load(unsafe &b[0])
    return (t as i32) + (w as i32) + (load_arr(unsafe &b[0]) as i32) - 34
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK:      :34:14: error [SC200E]: 'store' is @pure, so it cannot call '__builtin_copy'
// CHECK-NOT:  error [
