// A closure and the variable it captures by pointer, both from one macro
// invocation: the variable is declared outside the closure although every
// token of both is at the invocation.
macro counted!() {
    var n: i32 = 1
    var bump = fn ()|*n| { *n += 4 }
    bump()
    var outer = fn ()|*n| -> i32 {
        var inner = fn ()|*n| { *n += 10 }
        inner()
        var own: i32 = 100
        var add = fn ()|*own| { *own += 1 }
        add()
        return *n + own
    }

    return outer()
}

fn count() -> i32 {
    counted!()
}

fn main() -> i32 {
    return if count() == 116 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
