// A panicking operator, called through its own syntax. Its call is
// lowered and held by PanicLowering, ahead of OperatorLowering, and a
// derived form tests the call it is made of: `a != b` from a panicking
// `op ==` is `!(a.op==(b))` with the inner call held, `a < b` from `op <=>`
// compares the held Ordering, `a += b` from `op +` assigns the held sum, and
// `a + b` from `op +=` holds the in-place call. Before, every one of these
// was SC116E ("a call of a panicking operator"). Covered: a member binary
// operator, a free one, a unary one, a subscript, each derived form, a
// compound operator declared as such, an operator call inside another's
// operand, a `try` around each (statement and expression form), and a
// panic propagated through a `panic` function.
struct Overflow { var at: i32 }
struct Bad {}

struct Num {
    var v: i32
    fn op + (const self, o: Num) panic(Overflow) -> Num {
        if self.v + o.v > 100 { panic Overflow { at: self.v } }
        return Num { v: self.v + o.v }
    }
    fn op - (const self) panic(Bad) -> Num {
        if self.v == 0 { panic Bad {} }
        return Num { v: 0 - self.v }
    }
    fn op == (const self, o: Num) panic(Bad) -> bool {
        if o.v < 0 { panic Bad {} }
        return self.v == o.v
    }
    fn op [] (const self, i: i32) panic(Bad) -> i32 {
        if i < 0 { panic Bad {} }
        return self.v * i
    }
}

struct Rank {
    var v: i32
    fn op <=> (const self, o: Rank) panic(Bad) -> Ordering {
        if o.v < 0 { panic Bad {} }
        if self.v < o.v { return Ordering::Less }
        if self.v > o.v { return Ordering::Greater }
        return Ordering::Equal
    }
}

struct Acc {
    var v: i32
    fn op += (self, n: i32) panic(Overflow) {
        if self.v + n > 100 { panic Overflow { at: n } }
        self.v = self.v + n
    }
}

fn op * (a: Num, k: i32) panic(Overflow) -> Num {
    if k > 10 { panic Overflow { at: k } }
    return Num { v: a.v * k }
}

fn n(v: i32) -> Num { return Num { v: v } }

/// Through a bound: a requirement with a concrete result.
interface Gauge {
    fn op + (const self, k: i32) panic(Overflow) -> i32
}
struct Meter impl Gauge {
    var v: i32
    fn op + (const self, k: i32) panic(Overflow) -> i32 {
        if k > 50 { panic Overflow { at: k } }
        return self.v + k
    }
}
fn <T impl Gauge> plus(a: T, k: i32) panic -> i32 { return a + k }

/// Propagated, not handled: the caller's `try` sees it.
fn sum3(a: Num, b: Num, c: Num) panic -> i32 {
    var s = a + b + c
    return s.v
}

fn main() -> i32 {
    // Member binary, statement form `try` and expression form.
    var r = try (n(1) + n(2)).v catch e: Overflow => -1
    if r != 3 { return 1 }
    if (try (n(90) + n(20)).v catch e: Overflow => e.at) != 90 { return 2 }
    // Free operator.
    if (try (n(3) * 4).v catch e: Overflow => -1) != 12 { return 3 }
    if (try (n(3) * 11).v catch e: Overflow => e.at) != 11 { return 4 }
    // Unary.
    if (try (-n(5)).v catch e: Bad => 1) != -5 { return 5 }
    if (try (-n(0)).v catch e: Bad => 1) != 1 { return 6 }
    // Subscript.
    if (try n(7)[2] catch e: Bad => -1) != 14 { return 7 }
    if (try n(7)[-1] catch e: Bad => -1) != -1 { return 8 }
    // `==` and `!=` derived from it.
    if !(try n(2) == n(2) catch e: Bad => false) { return 9 }
    if (try n(2) != n(2) catch e: Bad => true) { return 10 }
    if !(try n(2) != n(-1) catch e: Bad => true) { return 11 }
    // `<` and `>=` derived from `<=>`.
    if !(try Rank { v: 1 } < Rank { v: 2 } catch e: Bad => false) { return 12 }
    if (try Rank { v: 3 } >= Rank { v: -2 } catch e: Bad => false) { return 13 }
    // `+=` from `op +`, the place evaluated once.
    var a = n(10)
    try { a += n(5) } catch e: Overflow { return 14 }
    if a.v != 15 { return 15 }
    try { a += n(99) } catch e: Overflow { a.v = e.at }
    if a.v != 15 { return 16 }
    // A compound operator declared as such.
    var c = Acc { v: 1 }
    try { c += 4 } catch e: Overflow { return 17 }
    if c.v != 5 { return 18 }
    try { c += 200 } catch e: Overflow { c.v = e.at }
    if c.v != 200 { return 19 }
    // `+` derived from that `op +=`: a copy, mutated in place.
    if (try (Acc { v: 2 } + 3).v catch e: Overflow => -1) != 5 { return 22 }
    if (try (Acc { v: 2 } + 300).v catch e: Overflow => e.at) != 300 { return 23 }
    // An operator call in another's operand, and one propagated.
    if (try sum3(n(1), n(2), n(3)) catch e: Overflow => -1) != 6 { return 20 }
    if (try sum3(n(60), n(30), n(20)) catch e: Overflow => e.at) != 90 { return 21 }
    if (try plus(Meter { v: 1 }, 2) catch e: Overflow => -1) != 3 { return 24 }
    if (try plus(Meter { v: 1 }, 60) catch e: Overflow => e.at) != 60 { return 25 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
