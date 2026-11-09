// An integer literal Sema types as `byte` from context reaches C++ as
// the enum class, not a plain int: initializers, arguments, returns and
// assignments. Compared through `as i32`; `byte & byte` is a separate gap.
import std::io

fn masked(b: byte) -> i32 {
    return b as i32
}

fn pick() -> byte {
    return 0x7F
}

fn main() -> i32 {
    var b: byte = 0xFF
    var z: byte = 0
    var a: byte = 1
    a = 0x80
    io::println(f"{b as i32} {z as i32} {a as i32} {masked(0xF0)} {pick() as i32}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: { %t.exe 2>&1 || true; } | %FileCheck %s
// CHECK: 255 0 128 240 127
