// A method's body `{` may sit on its own line, under a signature that wraps
// or one that does not. In a type body no member begins with `{`, so the
// newline in front of it cannot be ending a bodyless method. Before the fix
// each such `{` was S048E ("expected a field, method, or nested type") and
// the members after it cascaded; the compiler's own ImportProbe.k and
// SourceManager.k are written this way.
// The `->` of a wrapped signature may start its own line whatever the
// parameter list ends in: it used to work only after a typed parameter, so
// `fn f()` and `fn m(self)` with the arrow below them were S048E / S052E.
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 21

class C {
    var base: i32 = 1

    fn wrapped(self, x: i32)
        -> i32
    {
        return x + self.base
    }

    fn unwrapped(self, x: i32) -> i32
    {
        return x * 2
    }

    // The brace ending the return type's line still works beside them.
    fn trailing(self, x: i32)
        -> i32 {
        return x - 1
    }

    static fn make()
        -> C
    {
        return C()
    }

    fn one(self)
        -> i32 {
        return 1
    }
}

// Outside a type body the arrow joins too (the own-line `{` does not: there
// a bodyless `fn` may be followed by a bare block).
fn zero()
    -> i32 {
    return 0
}

struct S {
    var v: i32
}

// A bodyless requirement still ends at its newline.
interface Sized {
    fn size(self) -> i32
    fn twice(self) -> i32
}

extend S {
    fn get(self)
        -> i32
    {
        return self.v
    }

    fn twice(self)
        -> i32
    {
        return self.v * 2
    }
}

fn main() -> i32 {
    var c = C::make()
    var s: S
    s.v = 3
    // 3 + 8 + 4 + 3 + 6 + 1 + 0 - 4 = 21
    var sum = c.wrapped(2) + c.unwrapped(4) + c.trailing(5)
    return sum + s.get() + s.twice() + c.one() + zero() - 4
}
