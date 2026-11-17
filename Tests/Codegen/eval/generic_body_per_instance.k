// An `eval if` in a generic body whose condition depends on a type
// parameter is C++ `if constexpr`, decided per instance, and each instance
// instantiates only the branch it takes. What the other branch names is not
// explicitly instantiated for that instance: `bits<u8>` must not instantiate
// `__builtin_bitcast<u64, u8>`, which is an error (the sizes differ).
fn <T> bits(v: T) -> u64 {
    eval if __builtin_size_of<T>() == 8 {
        return __builtin_bitcast<u64, T>(v)
    } else {
        return 0
    }
}

fn <T> wide(v: T) -> u64 {
    eval if sizeof T == 8 {
        return __builtin_bitcast<u64, T>(v)
    } else if sizeof T == 4 {
        return __builtin_bitcast<u32, T>(v) as u64
    } else {
        return 1
    }
}

fn <T> moved(p: unsafe *T, q: unsafe *T) -> i32 {
    eval if __builtin_is_trivially_relocatable<T>() {
        unsafe { __builtin_copy(p as unsafe *u8, q as unsafe *const u8, __builtin_size_of<T>()) }
        return 1
    } else {
        return 2
    }
}

fn main() -> i32 {
    if bits(1.0 as f64) != 0x3FF0000000000000 { return 1 }
    if bits(7 as u8) != 0 { return 2 }
    if wide(1.0 as f32) != 0x3F800000 { return 3 }
    if wide(7 as u16) != 1 { return 4 }
    var a: u64 = 5
    var b: u64 = 9
    if moved(unsafe &a, unsafe &b) != 1 || a != 9 { return 5 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
