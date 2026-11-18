// `byte << n` and `byte >> n` take an integer count and give a `byte`, shifted
// as an unsigned 8-bit value: a count past the width gives 0 bits, not UB.
// A non-integer count is still rejected.

fn main() -> i32 {
    var a: byte = 3 as byte
    var b = a << 2
    var c = b >> 1
    var n: u32 = 9
    var d = a << n
    a <<= 1
    return (c as i32) + (d as i32) + (a as i32) - 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
