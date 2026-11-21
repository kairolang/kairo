// A member an `extend [T; N]` declares is the array's own and wins over
// its slice view's; a name the extension does not declare still reaches
// the view, and another array type has only the view's.

import std::io

extend [i32; 3] {
    fn size(const self) -> usize {
        return 30
    }

    fn first(const self) -> i32 {
        return self[2]
    }
}

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    var b: [i32; 4] = [5, 6, 7, 8]
    var *l? = a.last()
    var *f? = b.first()
    io::println(f"own size {a.size()} own first {a.first()} view last {(if l? => *l else => -1)}")
    io::println(f"other size {b.size()} other first {(if f? => *f else => -1)}")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      own size 30 own first 3 view last 3
// CHECK-NEXT: other size 4 other first 5
