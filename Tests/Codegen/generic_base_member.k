// A member a generic BASE declares, reached through a derived receiver,
// reads through the base instance the receiver derives: on `class Fixed
// derives Base<i32>`, Base's `fn get(self) -> T` is an i32 and its field
// `t` too. The receiver's own arguments were bound before (MONO.md G4.2),
// its bases' were not, so the result stayed `T`: unknown at type-check and
// an unbound member step in codegen (`f.wrap().t`).
//
// Shapes: a non-generic derived class, a generic one at its own argument
// (`Again<i64> derives Base<U>`), two levels (`Deep derives Again<i16>`),
// a field read, a method whose result is a record over T, and a call whose
// argument is ranked against the base's T.

class <T> Box {
    pub var v: T
}

class <T> Base {
    pub var t: T
    fn get(const self) -> T { return self.t }
    fn wrap(const self) -> Box<T> { return Box<T> { v: self.t } }
    fn set(self, v: T) { self.t = v }
}

class Fixed derives Base<i32> {
    fn Fixed(self) { self.t = 4 }
}

class <U> Again derives Base<U> {
    pub var extra: i32 = 0
}

class Deep derives Again<i16> {
    fn Deep(self) { self.t = 3 }
}

fn main() -> i32 {
    var f = Fixed()
    var a: i32 = f.get()
    var b: i32 = f.t
    var c: i32 = f.wrap().v
    f.set(10)

    var g = Again<i64>()
    g.set(20)
    var d: i64 = g.get()

    var h = Deep()
    var e: i16 = h.get()

    return a + b + c + f.get() + (d as i32) + (e as i32)   // 4 + 4 + 4 + 10 + 20 + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 45
