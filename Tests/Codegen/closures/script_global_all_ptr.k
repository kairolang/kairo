// In script mode a top-level `var` is a global (modules.mdx), and a
// global is named in place rather than captured, so `|*|` left `count` an
// i32 and `*count += 1` was SC070E; the same two lines inside `fn main()`
// worked. In the top-level code the script's own `var`s read as the
// locals they look like: `|*|` views each as a pointer to it and the body
// names its address (as for the named `|*count|`). A function of
// the script still names the global as a global, `|*|` or not.

import std::io

var count = 0
var total = 100

// `|*|`: every top-level `var` the body names is a pointer to it.
var bump = fn ()|*| { *count += 1 }
bump()
bump()
io::println(f"all {count}")

// `|const *count|`: read through the pointer, not a copy.
var peek = fn ()|const *count| -> i32 { return *count }
count = 40
io::println(f"const {peek()}")

// `|*|` naming two globals, one only read.
var add = fn (n: i32)|*| { *total += n + *count }
add(2)
io::println(f"two {total}")

// A closure made by a statement and called after it, from a function.
var later: fn() = fn ()|*| { *count *= 2 }
fn run_later() { later() }
run_later()
io::println(f"later {count}")

// Nested: the inner closure sees the outer one's pointer view.
var outer = fn ()|*| {
    var inner = fn () { *count += 1 }
    inner()
}
outer()
io::println(f"nested {count}")

// A function of the script names the global as a global, `|*|` or not.
fn in_fn() {
    var f = fn ()|*| { count += 1000 }
    f()
}
in_fn()
io::println(f"fn {count}")

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      all 2
// CHECK-NEXT: const 40
// CHECK-NEXT: two 142
// CHECK-NEXT: later 80
// CHECK-NEXT: nested 81
// CHECK-NEXT: fn 1081
