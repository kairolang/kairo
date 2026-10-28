// Every group of Lib/builtin/base/intrinsics.k and module.k's Kairo-only
// traits, run once: each wrong answer sets its own bit of the exit code.

class Pt { pub var x: i32 = 1
    fn Pt(self) { } }
struct Plain { var a: i32 }
enum Shape { Circle { r: i32 }, Dot }

fn main() -> i32 {
    var bad = 0
    // memory
    var a: [u8; 4] = [1, 2, 3, 4]
    var b: [u8; 4] = [0, 0, 0, 0]
    unsafe { __builtin_copy(unsafe &b[0], unsafe &a[0], 4) }
    if b[3] != 4 { bad += 1 }
    unsafe { __builtin_set_mem(unsafe &b[0], 9u8 as byte, 2) }
    if b[1] != 9 { bad += 2 }
    // bits
    var x: u32 = 8
    if __builtin_ctz(x) != 3 { bad += 4 }
    if __builtin_popcount(0xFFu8) != 8 { bad += 8 }
    if __builtin_bswap(0x0102u16) != 0x0201u16 { bad += 16 }
    if __builtin_rotl(0x81u8, 1) != 0x03u8 { bad += 32 }
    // overflow
    var r: i32 = 0
    if !__builtin_add_overflow(2147483647, 1, &r) { bad += 64 }
    // traits
    eval s1 = __builtin_is_same<i32, i32>()
    eval s2 = __builtin_is_integral<f64>()
    if (!s1) || s2 { bad += 128 }
    if __builtin_size_of<i64>() != 8 { bad += 256 }
    // Kairo-only
    if !__builtin_is_class<Pt>() || __builtin_is_class<Plain>() { bad += 512 }
    if !__builtin_is_struct<Plain>() || !__builtin_is_adt_enum<Shape>() { bad += 1024 }
    if !__builtin_is_nullable<i32?>() || (__builtin_tuple_arity<(i32, f64)>() != 2) { bad += 2048 }
    // atomics
    var y: i64 = 7
    __builtin_atomic_store(&y, 9i64, MemoryOrder::Release)
    if __builtin_atomic_fetch_add(&y, 1i64, MemoryOrder::SeqCst) != 9 { bad += 4096 }
    if __builtin_atomic_load(&y, MemoryOrder::Acquire) != 10 { bad += 8192 }
    // target
    eval ti = __builtin_target_info()
    if (!ti.is_linux()) || (!ti.is_64bit()) || (ti.arch != TargetArch::X86_64) { bad += 16384 }
    if !__builtin_expect(bad == 0, true) { return bad }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, host-x86_64, host-linux
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
