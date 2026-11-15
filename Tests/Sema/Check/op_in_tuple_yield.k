// `op in` may yield a tuple whose elements are pointers. Only a binder
// list destructures it, one binder per element, and each binder follows
// the rule of its own element:
//
//   element        through (self)                 through (const self)
//   T              a                              a, const a
//   *T             a (a copy), *a                 a, const a, const *a
//   *const T       a, const a, const *a           a, const a, const *a
//   unsafe *T      unsafe *a                      unsafe *a, const unsafe *a
//
// A `const` binder takes `op in (const self)` when the type declares it
// and no binder is a mutable `*a`. A lone binder over such a tuple is an
// error, and the two forms of a pair agree element by element (SC299E).

class Map {
    var k: i32 = 1
    var v: i32 = 2
    fn op in (self) -> yield (*const i32, *i32) { yield (&self.k as *const i32, &self.v) }
    fn op in (const self) -> yield (*const i32, *const i32) { yield (&self.k, &self.v) }
}

class Mixed {
    var a: i32 = 1
    var b: i32 = 2
    fn op in (self) -> yield (i32, *i32) { yield (self.a, &self.b) }
}

class Raw {
    var a: i32 = 1
    var b: i32 = 2
    fn op in (self) -> yield (unsafe *i32, *i32) {
        unsafe {
            yield (&self.a as unsafe *i32, &self.b)
        }
    }
}

class CRaw {
    var a: i32 = 1
    var b: i32 = 2
    fn op in (self) -> yield (unsafe *const i32, *i32) {
        unsafe {
            yield (&self.a as unsafe *const i32, &self.b)
        }
    }
}

class <T> Gen {
    var a: T
    var b: i32 = 2
    fn Gen(self, a: T) { self.a = a }
    fn op in (self) -> yield (T, *i32) { yield (self.a, &self.b) }
}

fn map_mutable(m: Map) -> i32 {
    var s = 0
    for (k, v) in m {
        s += k + v
    }

    for (k, *v) in m {
        *v = k
    }

    for (const *k, *v) in m {
        *v = *k
    }

    for (const k, v) in m {
        s += k + v
    }

    for (k, const v) in m {
        s += k + v
    }

    for (k, const *v) in m {
        s += k + *v
    }

    for (_, *v) in m {
        *v = 0
    }

    for _ in m {
        s += 1
    }

    // CHECK: op_in_tuple_yield.k:[[@LINE+2]]:10: error [SC298E]: the binder '*k' does not bind what 'op in (self)' yields: '*const i32' binds 'for k', 'for const k' or 'for const *k'; it points at a read-only element
    // CHECK-NEXT: fix-it:"{{.*}}op_in_tuple_yield.k":{[[@LINE+1]]:10-[[@LINE+1]]:12}:"const *k"
    for (*k, *v) in m {
        *v = 1
    }

    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:9: error [SC298E]: 'for e' does not bind what 'op in (self)' yields: '(*const i32, *i32)' holds a pointer, so it binds one binder per element, as 'for (e0, e1)'
    for e in m { }
    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:9: error [SC298E]: 'for *e' does not bind what 'op in (self)' yields
    for *e in m { }
    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:22: error [SC042E]: 3 binding(s) but '(*const i32, *i32)' has 2 element(s)
    for (a, b, c) in m { }
    return s
}

fn map_const(const c: Map) -> i32 {
    var s = 0
    for (k, v) in c {
        s += k + v
    }

    for (const *k, const *v) in c {
        s += *k + *v
    }

    for (const k, const v) in c {
        s += k + v
    }

    // CHECK: op_in_tuple_yield.k:[[@LINE+2]]:13: error [SC298E]: the binder '*v' does not bind what 'op in (const self)' yields: '*const i32' binds 'for v', 'for const v' or 'for const *v'; through 'const self' the element is read-only
    // CHECK-NEXT: fix-it:"{{.*}}op_in_tuple_yield.k":{[[@LINE+1]]:13-[[@LINE+1]]:15}:"const *v"
    for (k, *v) in c {
        s += k
    }

    return s
}

fn mixed(x: Mixed) -> i32 {
    var s = 0
    for (a, b) in x {
        s += a + b
    }

    for (a, *b) in x {
        *b = a
    }

    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:10: error [SC298E]: the binder '*a' does not bind what 'op in (self)' yields: 'i32' binds only 'for a'; to bind a pointer to it, declare that element '*i32'
    for (*a, b) in x { }
    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:10: error [SC298E]: the binder 'const a' does not bind what 'op in (self)' yields: 'i32' binds only 'for a'; 'Mixed' declares no 'op in (const self)'
    for (const a, b) in x { }
    return s
}

fn raw(r: Raw) -> i32 {
    var s = 0
    for (unsafe *a, *b) in r {
        unsafe {
            *b = *a
        }
    }

    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:10: error [SC298E]: the binder 'a' does not bind what 'op in (self)' yields: 'unsafe *i32' binds only 'for unsafe *a'
    for (a, b) in r { }
    return s
}

// An `unsafe *const T` element reads as the `const self` row.
fn craw(r: CRaw) -> i32 {
    var s = 0
    for (const unsafe *a, *b) in r {
        unsafe {
            *b = *a
        }
    }

    for (unsafe *a, _) in r {
        unsafe {
            s += *a
        }
    }

    return s
}

// The rule is read off the declaration: an element written `T` yields a
// value whatever `T` is.
fn generic(g: Gen<*i32>) -> i32 {
    var s = 0
    for (a, *b) in g {
        s += *a + *b
    }

    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:10: error [SC298E]: the binder '*a' does not bind what 'op in (self)' yields: '*i32' binds only 'for a'
    for (*a, b) in g { }
    return s
}

class Disagree {
    var a: i32 = 1
    fn op in (self) -> yield (*i32, *i32) { yield (&self.a, &self.a) }
    // CHECK: op_in_tuple_yield.k:[[@LINE+1]]:5: error [SC299E]: 'op in' yields a tuple ('(*T, T)') here and a tuple ('(*T, *T)') in its other form; 'op in (self)' and 'op in (const self)' yield one form
    fn op in (const self) -> yield (*const i32, i32) { yield (&self.a, self.a) }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
