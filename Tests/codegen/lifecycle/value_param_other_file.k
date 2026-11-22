// What a call does with a by-value argument of a destructive class depends
// on the callee's body only where that body is compiled with the call. A
// function of another file is compiled into that file's object, and a
// change to its body does not compile this file again, so a call of it
// passes an object of the call's own whatever the body does: correct
// against every body the other file can have. Where that body moves the
// value on, the call destroys the emptied object it made (the two
// `empties`). A function of this file and a generic function of the other
// file are compiled with the call, and the call hands them the caller's
// object: nothing emptied is destroyed.
import std::io::println
import self::inputs::value_param_lib::*

fn here(r: R) -> i32 {
    var mine = r
    return mine.id
}

fn caller() -> i32 {
    var a = R(1)
    var b = R(2)
    var c = R(3)
    var d = R(4)
    var n = take(a)
    n += peek(b)
    n += here(c)
    n += wrap<i32>(d, 0)
    n += take(R(5))
    return n
}

fn main() -> i32 {
    var n = caller()
    println(f"sum {n} made {made} ended {ended} empties {empties}")
    return if made == ended => 0 else => 1
}

// --- lit wiring ---
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
// RUN: rm -f %t.o2.exe
// RUN: %kairo %s -O2 -o %t.o2.exe
// RUN: %t.o2.exe | %FileCheck %s

// CHECK: sum 15 made 5 ended 5 empties 2

// CXX-LABEL: CODEGEN C++: {{.*}}value_param_other_file.k
// CXX: signed int caller() noexcept {
// CXX: take(static_cast<{{.*}}R{{ ?}}>(static_cast<{{.*}}R{{ ?}}&&>(__k_s_a.v)));
// CXX: peek(static_cast<{{.*}}R{{ ?}}>(static_cast<{{.*}}R{{ ?}}&&>(__k_s_b.v)))
// CXX: here(static_cast<{{.*}}R{{ ?}}&&>(__k_s_c.v))
// CXX: wrap<signed int>(static_cast<{{.*}}R{{ ?}}&&>(__k_s_d.v), 0)
// CXX: take({{.*}}R(5))
