// A 128-bit integer keys a map or a set: its hash feeds both 64-bit halves,
// so keys that differ only above bit 63 stay distinct.

fn main() -> i32 {
    var c: {u128: i32}
    var d: {i128: i32}
    var s: {u128}
    c[1u128 << 100] = 3
    c[1] = 4
    d[-5] = 6
    s.insert(1u128 << 64)
    s.insert(1)
    if c.size() != 2 || !c.contains(1u128 << 100) || c.contains(2) { return 1 }
    if s.size() != 2 || !s.contains(1u128 << 64) { return 2 }
    return d.size() as i32 + 41
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
