// Types that meet the two-word library's interfaces with no Kairo code:
// a float meets Ord through its own comparison, and a pointer meets Hash
// by feeding its address to the Hasher the requirement takes.

import std::io

fn <T impl Ord> larger(a: T, b: T) -> T {
    if (a <=> b) == Ordering::Less { return b }
    return a
}

fn <K impl Hash> feed(const k: K, @inout h: Hasher) {
    k.hash(&h)
}

// Compiled and linked, not run: Hasher has no body yet.
fn feed_pointer(p: *i32, @inout h: Hasher) {
    feed(p, &h)
}

fn main() -> i32 {
    io::println(f"{larger(1.5, 2.5)} {larger(3, 2)}")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: 2.5 3
