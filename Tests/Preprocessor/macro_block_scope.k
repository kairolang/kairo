// A macro defined in a block is visible to the end of that block: two
// function bodies each define their own `arm!`, a nested block sees the
// enclosing block's macro, and a type body's macro stays in the type. An
// `eval if` branch is no block: its macro is the enclosing scope's.
fn low() -> i32 {
    macro arm!(K) { K + 1 }
    return arm!(1)
}

fn high() -> i32 {
    macro arm!(K) { K + 10 }
    if true {
        return arm!(1)
    }

    return 0
}

class Sized {
    macro WIDTH! { 100 }
    pub var w: i32 = WIDTH!

    pub fn Sized(self) { }
}

macro ON! { true }

eval if defined!(ON) {
    macro WIDE! { 7 }
}
else {
    macro NARROW! { 1 }
}

fn main() -> i32 {
    var s = Sized()
    return if low() + high() + s.w + WIDE! + NARROW! == 121 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
