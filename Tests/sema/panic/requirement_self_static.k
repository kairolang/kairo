// A static interface requirement that panics and whose result names `Self`
// (`static fn make(s) panic(E) -> Self`): each conformer returns its own
// type, a class's and a primitive's alike, and a call through a bound
// (`T::make(s)`) returns the bound's type. A requirement whose panic SET
// names `Self` stays SC116E, as does a method requirement whose result
// names it (requirement_self.k).

import std::io::println

struct Bad {
    var at: i32
}

interface Make {
    static fn make(const s: string) panic(Bad) -> Self
    static fn maybe(const s: string) panic(Bad) -> Self?
}

class Word impl Make {
    pub var n: i32
    fn Word(self, n: i32) { self.n = n }

    static fn make(const s: string) panic(Bad) -> Word {
        if s.is_empty() {
            panic Bad { at: 0 }
        }

        return Word(s.size() as i32)
    }

    static fn maybe(const s: string) panic(Bad) -> Word? {
        if s == "x" {
            panic Bad { at: 1 }
        }

        if s.is_empty() {
            return null
        }

        return Word(s.size() as i32)
    }
}

extend i32 impl Make {
    static fn make(const s: string) panic(Bad) -> i32 {
        if s.is_empty() {
            panic Bad { at: 2 }
        }

        return s.size() as i32 * 10
    }

    // A conformer may raise less than its requirement.
    static fn maybe(const s: string) -> i32? = null
}

fn <T impl Make> via(const s: string) panic(Bad) -> T = T::make(s)

fn <T impl Make> via_maybe(const s: string) panic(Bad) -> T? {
    return T::maybe(s)
}

// The call through the bound caught where it is made, and bound to a local
// before it is returned.
fn <T impl Make> or_else(const s: string, fallback: T) -> T {
    return try T::make(s) catch e: Bad => fallback
}

fn <T impl Make> held(const s: string) panic(Bad) -> T {
    var v = T::make(s)
    return v
}

fn main() -> i32 {
    var bad = 0
    var w = try via<Word>("abc") catch e: Bad => Word(-1)
    if w.n != 3 { bad += 1 }
    var x = try via<Word>("") catch e: Bad => Word(-e.at - 10)
    if x.n != -10 { bad += 2 }
    var i = try via<i32>("ab") catch e: Bad => -1
    if i != 20 { bad += 4 }
    var j = try via<i32>("") catch e: Bad => -e.at
    if j != -2 { bad += 8 }
    var d = try Word::make("hello") catch e: Bad => Word(-1)
    if d.n != 5 { bad += 16 }
    var k = try i32::make("z") catch e: Bad => -1
    if k != 10 { bad += 32 }
    var m: Word? = try via_maybe<Word>("") catch e: Bad => Word(-1)
    if m? { bad += 64 }
    var n: Word? = try via_maybe<Word>("x") catch e: Bad => Word(-e.at)
    if !n? || n.n != -1 { bad += 128 }
    var o: i32? = try via_maybe<i32>("q") catch e: Bad => 5
    if o? { bad += 256 }
    var q = or_else<i32>("abc", 7)
    if q != 30 { bad += 512 }
    var r = or_else<i32>("", 7)
    if r != 7 { bad += 1024 }
    var t = or_else<Word>("", Word(9))
    if t.n != 9 { bad += 2048 }
    var u = try held<Word>("four") catch e: Bad => Word(-1)
    if u.n != 4 { bad += 4096 }
    var v = try held<i32>("") catch e: Bad => -e.at
    if v != -2 { bad += 8192 }
    println(f"bad={bad}")

    return bad
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: bad=0
