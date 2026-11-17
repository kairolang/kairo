// A requirement whose signature names `Self::Item?` (interfaces.mdx,
// Associated Types): a conformance's witness specialization returns or takes
// `Null<Item>` at the row's own Item, so the nullable record is defined
// before the specialization whatever Item is -- a builtin, a user struct, a
// pointer, another generic instance (a vector, a tuple) -- and through a
// derived interface and a generic adapter whose own Item is derived from
// its parameter's. Conformers and adapter instances are also named in
// signatures and fields, outside any body.

interface It {
    type Item
    fn next(self) -> Self::Item?
}

interface Back derives It {
    fn next_back(self) -> Self::Item?
}

interface Sink {
    type Item
    fn put(self, v: Self::Item?) -> i32
}

struct P {
    var a: i32
    var b: i32
}

class Count {
    var n: i32 = 0
    var end: i32 = 3
    fn Count(self) { }
}

extend Count impl Back {
    type Item = i32
    fn next(self) -> i32? {
        if self.n == self.end {
            return null
        }

        self.n += 1
        return self.n
    }
    fn next_back(self) -> i32? {
        if self.n == self.end {
            return null
        }

        self.end -= 1
        return self.end + 1
    }
}

class Points {
    var n: i32 = 0
    fn Points(self) { }
}

extend Points impl It {
    type Item = P
    fn next(self) -> P? {
        if self.n == 2 {
            return null
        }

        self.n += 1
        return P { a: self.n, b: 10 }
    }
}

class Refs {
    var p: P = P { a: 7, b: 0 }
    var done: bool = false
    fn Refs(self) { }
}

extend Refs impl It {
    type Item = *P
    fn next(self) -> (*P)? {
        if self.done {
            return null
        }

        self.done = true
        return &self.p
    }
}

class Lists {
    var n: i32 = 0
    fn Lists(self) { }
}

extend Lists impl It {
    type Item = [i32]
    fn next(self) -> [i32]? {
        if self.n == 1 {
            return null
        }

        self.n += 1
        var v: [i32]
        v.push(4)
        v.push(5)
        return v
    }
}

class Pairs {
    var n: i32 = 0
    fn Pairs(self) { }
}

extend Pairs impl It {
    type Item = (i32, i64)
    fn next(self) -> (i32, i64)? {
        if self.n == 2 {
            return null
        }

        self.n += 1
        return (self.n, 100)
    }
}

class Tally {
    var sum: i32 = 0
    fn Tally(self) { }
}

extend Tally impl Sink {
    type Item = i32
    fn put(self, v: i32?) -> i32 {
        if v == null {
            return self.sum
        }

        self.sum += v ?? 0
        return self.sum
    }
}

// An adapter: its Item is derived from its parameter's, and next forwards.
class <I impl It> Doubled {
    var it: I
    fn Doubled(self, it: I) { self.it = it }
}

extend <I impl It> Doubled<I> impl It {
    type Item = I::Item
    fn next(self) -> I::Item? {
        return self.it.next()
    }
}

// Its own Item, not its parameter's: a row over a different Item.
class <I impl It> Widen {
    var it: I
    var k: i64 = 0
    fn Widen(self, it: I) { self.it = it }
}

extend <I impl It> Widen<I> impl It {
    type Item = i64
    fn next(self) -> i64? {
        if self.it.next() == null {
            return null
        }

        self.k += 2
        return self.k
    }
}

fn <I impl It> drain(it: I) -> i32 {
    var k = 0
    while it.next() != null {
        k += 1
    }

    return k
}

fn <I impl Back> drain_back(it: I) -> i32 {
    var k = 0
    while it.next_back() != null {
        k += 1
    }

    return k
}

fn <S impl Sink> feed(s: S, v: S::Item?) -> i32 {
    return s.put(v)
}

// Named in a signature and a field, outside a body.
fn make() -> Count {
    return Count()
}

fn wrap(c: Count) -> Widen<Count> {
    return Widen<Count>(c)
}

class Holder {
    var w: Widen<Count>
    fn Holder(self) { self.w = Widen<Count>(Count()) }
}

fn main() -> i32 {
    var r = 0
    r += drain(make())                                // 3
    r += drain_back(Count())                          // 3
    r += drain(Points())                              // 2
    r += drain(Refs())                                // 1
    r += drain(Lists())                               // 1
    r += drain(Pairs())                               // 2
    r += drain(Doubled<Points>(Points()))             // 2
    r += drain(wrap(Count()))                         // 3
    var h = Holder()
    r += drain(h.w)                                   // 3
    var t = Tally()
    r += feed<Tally>(t, 5) - 5                               // 0
    r += feed<Tally>(t, null)                                // 0: t is passed by value
    var w = Widen<Count>(Count())
    var x? = w.next()
    r += ((x ?? 0) as i32)                                // 2
    return r                                          // 22
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
