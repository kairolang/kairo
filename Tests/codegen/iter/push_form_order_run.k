// A `for` over a generator call behaves the same whether the generator runs
// as a coroutine or as its push form: the order of the generator's steps,
// the loop body, and every destructor, for a loop that ends, breaks,
// continues, returns a value, or is nested in another.

import std::io::println

class Noisy {
    var tag: i32
    fn Noisy(self, tag: i32) {
        self.tag = tag
        println(f"  make {tag}")
    }
    @move fn Noisy(self, other: Self) {
        self.tag  = other.tag
        other.tag = -other.tag
        println(f"  move {self.tag}")
    }
    fn op finally(self) {
        println(f"  drop {self.tag}")
    }
}

fn count(n: i32) -> yield i32 {
    var guard = Noisy(100)
    println("  gen start")
    for var i: i32 = 0; i < n; i += 1 {
        var step = Noisy(200 + i)
        yield i
        println(f"  gen after {i}")
    }
    println("  gen end")
}

fn pairs(n: i32) -> yield i32 {
    for a in count(n) {
        yield a * 10
        if a == 1 { return }
    }
}

fn evens(n: i32) -> yield i32 {
    for v in count(n) {
        if v % 2 == 1 { continue }
        yield v
    }
}

fn whole() {
    println("whole:")
    for v in count(2) {
        var body = Noisy(v + 1)
        println(f"  body {v}")
    }
    println("  after")
}

fn broken() {
    println("broken:")
    for v in count(5) {
        var body = Noisy(v + 1)
        if v == 1 { break }
        println(f"  body {v}")
    }
    println("  after")
}

fn skipped() -> i32 {
    println("skipped:")
    var sum: i32 = 0
    for v in count(4) {
        if v % 2 == 0 { continue }
        sum += v
    }
    return sum
}

fn found(want: i32) -> i32 {
    println("found:")
    var outer = Noisy(7)
    for v in count(5) {
        var body = Noisy(v + 1)
        if v == want { return v * 100 }
    }
    return -1
}

fn nested() -> i32 {
    println("nested:")
    var sum: i32 = 0
    for a in count(2) {
        for b in count(2) {
            if b == 1 { break }
            sum += a * 10 + b + 1
        }
    }
    return sum
}

fn piped() -> i32 {
    println("piped:")
    var sum: i32 = 0
    for v in pairs(5) { sum += v }
    for v in evens(3) { sum += v * 1000 }
    return sum
}

fn main() -> i32 {
    whole()
    broken()
    println(f"  = {skipped()}")
    println(f"  = {found(1)}")
    println(f"  = {found(9)}")
    println(f"  = {nested()}")
    println(f"  = {piped()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// The same at -O2, where the push form is inlined into each loop.
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      whole:
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   make 1
// OUT-NEXT:   body 0
// OUT-NEXT:   drop 1
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   make 2
// OUT-NEXT:   body 1
// OUT-NEXT:   drop 2
// OUT-NEXT:   gen after 1
// OUT-NEXT:   drop 201
// OUT-NEXT:   gen end
// OUT-NEXT:   drop 100
// OUT-NEXT:   after
// OUT-NEXT: broken:
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   make 1
// OUT-NEXT:   body 0
// OUT-NEXT:   drop 1
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   make 2
// OUT-NEXT:   drop 2
// OUT-NEXT:   drop 201
// OUT-NEXT:   drop 100
// OUT-NEXT:   after
// OUT-NEXT: skipped:
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   gen after 1
// OUT-NEXT:   drop 201
// OUT-NEXT:   make 202
// OUT-NEXT:   gen after 2
// OUT-NEXT:   drop 202
// OUT-NEXT:   make 203
// OUT-NEXT:   gen after 3
// OUT-NEXT:   drop 203
// OUT-NEXT:   gen end
// OUT-NEXT:   drop 100
// OUT-NEXT:   = 4
// OUT-NEXT: found:
// OUT-NEXT:   make 7
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   make 1
// OUT-NEXT:   drop 1
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   make 2
// OUT-NEXT:   drop 2
// OUT-NEXT:   drop 201
// OUT-NEXT:   drop 100
// OUT-NEXT:   drop 7
// OUT-NEXT:   = 100
// OUT-NEXT: found:
// OUT-NEXT:   make 7
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   make 1
// OUT-NEXT:   drop 1
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   make 2
// OUT-NEXT:   drop 2
// OUT-NEXT:   gen after 1
// OUT-NEXT:   drop 201
// OUT-NEXT:   make 202
// OUT-NEXT:   make 3
// OUT-NEXT:   drop 3
// OUT-NEXT:   gen after 2
// OUT-NEXT:   drop 202
// OUT-NEXT:   make 203
// OUT-NEXT:   make 4
// OUT-NEXT:   drop 4
// OUT-NEXT:   gen after 3
// OUT-NEXT:   drop 203
// OUT-NEXT:   make 204
// OUT-NEXT:   make 5
// OUT-NEXT:   drop 5
// OUT-NEXT:   gen after 4
// OUT-NEXT:   drop 204
// OUT-NEXT:   gen end
// OUT-NEXT:   drop 100
// OUT-NEXT:   drop 7
// OUT-NEXT:   = -1
// OUT-NEXT: nested:
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   drop 201
// OUT-NEXT:   drop 100
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   drop 201
// OUT-NEXT:   drop 100
// OUT-NEXT:   gen after 1
// OUT-NEXT:   drop 201
// OUT-NEXT:   gen end
// OUT-NEXT:   drop 100
// OUT-NEXT:   = 12
// OUT-NEXT: piped:
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   drop 201
// OUT-NEXT:   drop 100
// OUT-NEXT:   make 100
// OUT-NEXT:   gen start
// OUT-NEXT:   make 200
// OUT-NEXT:   gen after 0
// OUT-NEXT:   drop 200
// OUT-NEXT:   make 201
// OUT-NEXT:   gen after 1
// OUT-NEXT:   drop 201
// OUT-NEXT:   make 202
// OUT-NEXT:   gen after 2
// OUT-NEXT:   drop 202
// OUT-NEXT:   gen end
// OUT-NEXT:   drop 100
// OUT-NEXT:   = 2010
