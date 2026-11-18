// An assignment's target is bound before the value is read only when the
// target has an effect. Targets without an effect read the value as
// written: `arr[0] = p`, `arr[p] = p` with no increment, and a value that
// itself has the effect (`arr[2] = p++`) stores the pre-increment value.
// Checked at -O0 and -O2.
import std::io

fn main() -> i32 {
    var arr: [i32; 4] = [9, 9, 9, 9]
    var p = 3
    arr[0] = p
    io::println(f"arr[0] = p: {arr[0]}")
    arr[p] = p
    io::println(f"arr[p] = p: {arr[3]}")
    var q = 1
    arr[2] = q++
    io::println(f"arr[2] = q++: {arr[2]} q={q}")
    var r = 0
    arr[1] = r++ + r
    io::println(f"arr[1] = r++ + r: {arr[1]} r={r}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: arr[0] = p: 3
// OUT-NEXT: arr[p] = p: 3
// OUT-NEXT: arr[2] = q++: 1 q=2
// OUT-NEXT: arr[1] = r++ + r: 1 r=1
