// A fixed array passed where a generic callee takes a slice (`[const T;]`
// of an `extend <T> Slice<T>` member: `op ==`, `starts_with`) is viewed
// as the instance's Slice. C++ deduces no template argument through the
// conversion, so the view is spelled at the argument.

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    var b: [i32; 3] = [1, 2, 3]
    var c: [i32; 2] = [1, 2]
    var s: [i32;] = a
    var e = s == b
    var w = s.starts_with(c)
    var n = s == c
    return if (e && w && !n) => (0) else => 1
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
