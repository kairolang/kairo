// What a closure body does with control flow and with the lowerings that
// run over it. `return` returns from the CLOSURE, with the closure's value,
// and the enclosing function goes on. A `finally` in a closure runs when
// the closure's block is left, on every path, and sees what the body
// sees there: the closure's parameter, its own copy of a by-copy capture,
// a `|*x|` capture through the pointer, and `self`. Nullable narrowing
// holds inside: a by-copy capture of a checked nullable is read as its
// value. A loop, an f-string and a match in the body are lowered as in
// any function.

import std::io::println

class Log {
    pub var n: i32 = 0
    fn guarded(self) -> i32 {
        var f = fn (k: i32) -> i32 {
            finally { self.n += k }
            return k * 2
        }
        f(1)
        f(2)
        return self.n
    }
}

enum Level { Low, High }

fn early(xs: i32) -> i32 {
    var pick = fn (v: i32) -> i32 {
        if v > 10 { return 1 }
        return 2
    }
    var r = pick(xs)
    return r * 100 + pick(xs + 20)
}

fn main() -> i32 {
    println(f"return: {early(5)}")

    var hits = 0
    var tag = 7
    var guard = fn (k: i32)|*hits, tag| -> i32 {
        finally { *hits += k + tag }
        if k > 0 { return k }
        return 0 - k
    }
    var r = guard(3) + guard(0 - 4)
    println(f"finally: {r} hits: {hits}")
    println(f"self finally: {Log().guarded()}")

    var a: i32? = 4
    if a? {
        var f = fn () -> i32 { return a + 1 }
        println(f"narrowed: {f()}")
    }

    var sum = fn (n: i32) -> string {
        var t = 0
        for i in 0..n { t += i }
        var lvl = Level::High
        if t < 5 { lvl = Level::Low }
        var w = match lvl {
            case .Low  => "low"
            case .High => "high"
        }
        return f"{t}/{w}"
    }
    println(f"lowered: {sum(3)} {sum(5)}")
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
// OUT:      return: 201
// OUT-NEXT: finally: 7 hits: 13
// OUT-NEXT: self finally: 3
// OUT-NEXT: narrowed: 5
// OUT-NEXT: lowered: 3/low 10/high
