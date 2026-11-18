// A C++ `bool&` (an `array<bool, N>` element) is a condition: it is read as
// the bool it refers to, as `!` and `&&` already read it.

ffi "c++" import "array";

fn f(t: cxx::std::array<bool, 4>) -> i32 {
    if t[0] { return 1; }
    while t[1] { break; }
    var e = if t[2] => 2 else => 3;
    if !t[3] && t[0] { return 4; }
    return e;
}

fn main() -> i32 {
    var t = cxx::std::array<bool, 4>();
    t[2] = true;
    return f(t);   // 2
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
// CHECK-NOT: SC084E
