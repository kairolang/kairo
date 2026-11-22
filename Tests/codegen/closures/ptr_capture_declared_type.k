// A binding captured by pointer is a `*T` inside the closure whatever its
// declaration spells: `var s: S` and `var s = S {}` read the same there.
// A method call on it goes through `->` and receives the original, for a
// method an `extend` adds (mutating or const), a vector's own method, a
// method of a generic record, an `@inout` parameter, a binding taken by
// `|*|` or `|const *x|`, and an inner closure that copies an outer one's
// pointer capture. `.` on such a binding is R027E, as on any pointer.

import std::io::println

struct S {
    var n: i32
}

extend S {
    fn bump(self) {
        self.n += 1
    }

    fn get(const self) -> i32 {
        return self.n
    }
}

struct <T> Box {
    var value: T
}

extend <T> Box<T> {
    fn set(self, v: T) {
        self.value = v
    }
}

fn bump_param(@inout p: S) {
    var f = fn ()|*p| { p->bump() }
    f()
}

fn main() -> i32 {
    var s:   S = S { n: 1 }
    var bump   = fn ()|*s| { s->bump() }
    bump()
    bump()
    var read = fn ()|const *s| -> i32 { return s->get() }
    println(f"named: {s.n} const: {read()}")

    var st:  [i32] = []
    var push       = fn (r: i32)|*st| { st->push(r) }
    push(3)
    push(4)
    println(f"vector: {st.size()} {st[1]}")

    var b:  Box<i32> = Box<i32> { value: 0 }
    var set          = fn (v: i32)|*b| { b->set(v) }
    set(7)
    println(f"generic: {b.value}")

    var a:  S = S { n: 10 }
    var all   = fn ()|*| { a->bump() }
    all()
    println(f"all: {a.n}")

    var o: S = S { n: 20 }
    var outer = fn ()|*o| {
        var inner = fn () { o->bump() }
        inner()
        var inner_ptr = fn ()|*o| { o->bump() }
        inner_ptr()
    }

    outer()
    println(f"nested: {o.n}")

    var q: S = S { n: 30 }
    bump_param(&q)
    println(f"param: {q.n}")
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %S/inputs/ptr_capture_declared_type_dot.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DOT
// DOT: ptr_capture_declared_type_dot.k:13:35: error [R027E]: '.' cannot be applied to a pointer; use '->'
// DOT: ptr_capture_declared_type_dot.k:15:43: error [R027E]: '.' cannot be applied to a pointer; use '->'
// DOT-NOT: error

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      named: 3 const: 3
// OUT-NEXT: vector: 2 4
// OUT-NEXT: generic: 7
// OUT-NEXT: all: 11
// OUT-NEXT: nested: 22
// OUT-NEXT: param: 31
