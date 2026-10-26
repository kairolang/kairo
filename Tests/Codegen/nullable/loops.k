// G13 (Compiler/Sema/NULLABLE.md 3.5), run: the loops the analysis keeps a
// nullable proven through compile to `__value()` reads and compute what
// the source says. A body that only gives `x` proven values; one that
// nulls it and gives it a value again before the back edge; `while x?`
// walking a list whose next link is nullable; a `loop` left only by a
// break that proved it; a `for` over a range that never touches it; an
// inner loop whose null is overwritten before its break; and a labeled
// break out of an outer `loop`.

import std::io::println

class Node {
    pub var v: i32
    pub var next: (*Node)? = null
    pub fn Node(self, v: i32) { self.v = v }
}

fn find(k: i32) -> i32? { if k > 3 { return k } return null }
fn val(k: i32) -> i32 { return k * 2 }

fn main() -> i32 {
    var x: i32? = 1
    var r = 0
    while r < 20 {
        r += x
        x = val(r)
    }
    println(f"values: {r} {x}")

    var y: i32? = 1
    var s = 0
    for k in 0..4 {
        s += y
        y = null
        y = k + 10
    }
    println(f"reestablished: {s} {y}")

    var c = Node(3)
    var b = Node(2)
    var a = Node(1)
    b.next = &c
    a.next = &b
    var node: (*Node)? = &a
    var sum = 0
    while node? {
        sum += node->v
        node = node->next
    }
    println(f"list: {sum}")

    var z: i32? = null
    var i = 0
    loop {
        i += 1
        z = find(i)
        if z? { break }
    }
    println(f"loop: {z + 0} after {i}")

    var w: i32? = 5
    var t = 0
    for k in 0..3 { t += w + k }
    println(f"for: {t}")

    var u: i32? = 1
    var q = 0
    while q < 3 {
        q += u
        loop {
            u = null
            u = q
            break
        }
    }
    println(f"inner: {q} {u}")

    var v: i32? = null
    outer: loop {
        while true {
            v = 4
            break outer
        }
    }
    println(f"labeled: {v + 0}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      values: 27 54
// OUT-NEXT: reestablished: 34 13
// OUT-NEXT: list: 6
// OUT-NEXT: loop: 4 after 4
// OUT-NEXT: for: 18
// OUT-NEXT: inner: 4 4
// OUT-NEXT: labeled: 4
