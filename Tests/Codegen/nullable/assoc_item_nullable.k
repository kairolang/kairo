// A nullable of an associated type read through a bounded parameter,
// `I::Item?`, takes every nullable form in a generic body: `??` with a
// literal, with a value of another type and with an `I::Item`, the `?`
// test as a value and as a condition, `unwrap!`, `?.` on an `Item` bound
// by an interface, and narrowing after `if x == null { return }`.

interface Getter {
    fn get(const self) -> i32
}

class Num {
    pub var v: i32

    pub fn Num(self) {
        self.v = 0
    }

    pub fn Num(self, v: i32) {
        self.v = v
    }

    pub fn get(const self) -> i32 {
        return self.v
    }
}

extend Num impl Getter {}

interface Src {
    type Item
    fn next(self) -> Self::Item?
}

interface Boxed {
    type Item impl Getter
    fn next(self) -> Self::Item?
}

class Four {
    var n: i32 = 0
}

extend Four impl Src {
    type Item = i32
    fn next(self) -> i32? { return 4 }
}

class Empty {
    var n: i32 = 0
}

extend Empty impl Src {
    type Item = i32
    fn next(self) -> i32? { return null }
}

class Five {
    var n: i32 = 0
}

extend Five impl Boxed {
    type Item = Num
    fn next(self) -> Num? { return Num(5) }
}

fn <I impl Src> twice(it: I) -> i64 requires __builtin_is_same<I::Item, i32>() {
    var x = it.next()
    return ((x ?? 0) as i64) * 2
}

fn <I impl Src> plus(it: I) -> i64 {
    var x = it.next()
    var y: i64 = 7
    return ((x ?? 1) as i64) + y
}

fn <I impl Src> or_else(it: I, d: I::Item) -> I::Item {
    var x = it.next()
    return x ?? d
}

fn <I impl Src> or_call(it: I, d: I::Item) -> I::Item {
    return it.next() ?? d
}

fn <I impl Src> plus_call(it: I) -> i64 {
    return (it.next() ?? 1) as i64
}

fn <I impl Src> has(it: I) -> i32 {
    var x = it.next()
    var b = if (x?) => 1 else => 0
    if x? {
        return b + 10
    }

    return b
}

fn <I impl Src> forced(it: I) -> I::Item {
    var x = it.next()
    return unwrap!(x)
}

fn <I impl Src> narrowed(it: I, d: I::Item) -> I::Item {
    var x = it.next()
    if x == null {
        return d
    }

    return x
}

fn <I impl Boxed> got(it: I) -> i32 {
    var x = it.next()
    return x?.get() ?? 0
}

fn <I impl Boxed> got_narrowed(it: I) -> i32 {
    var x = it.next()
    if x? {
        return x.get()
    }

    return 0
}

fn main() -> i32 {
    if twice(Four()) != 8 || plus(Four()) != 11 || plus(Empty()) != 8 {
        return 1
    }

    if or_else<Four>(Four(), 1) != 4 || or_else<Empty>(Empty(), 1) != 1 {
        return 2
    }

    if or_call<Empty>(Empty(), 6) != 6 || or_call<Four>(Four(), 6) != 4 || plus_call(Empty()) != 1 {
        return 6
    }

    if has(Four()) != 11 || has(Empty()) != 0 || forced(Four()) != 4 {
        return 3
    }

    if narrowed<Four>(Four(), 9) != 4 || narrowed<Empty>(Empty(), 9) != 9 {
        return 4
    }

    if got(Five()) != 5 || got_narrowed(Five()) != 5 {
        return 5
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
