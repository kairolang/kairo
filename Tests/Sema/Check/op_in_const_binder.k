// A `const` binder reads through `op in (const self)` when the type declares
// one, over a mutable object too: `for const x in s` and `for const *x in s`
// take the const form. A mutable pointer binder beside it (`*x`) keeps the
// loop on `op in (self)`. With no const form, a `const` binder is SC298E and
// the message says the type declares none.

class VPair {
    var a: i32 = 1
    fn op in (self) -> yield i32 { yield self.a }
    fn op in (const self) -> yield i32 { yield self.a }
}

class PPair {
    var a: i32 = 1
    fn op in (self) -> yield *i32 { yield &self.a }
    fn op in (const self) -> yield *const i32 { yield &self.a }
}

class TPair {
    var a: i32 = 1
    var b: i32 = 2
    fn op in (self) -> yield (i32, i32) { yield (self.a, self.b) }
    fn op in (const self) -> yield (i32, i32) { yield (self.a, self.b) }
}

class PTuple {
    var a: i32 = 1
    var b: i32 = 2
    fn op in (self) -> yield (*i32, *i32) { yield (&self.a, &self.b) }
    fn op in (const self) -> yield (*const i32, *const i32) { yield (&self.a, &self.b) }
}

class VOnly {
    var a: i32 = 1
    fn op in (self) -> yield i32 { yield self.a }
}

class POnly {
    var a: i32 = 1
    fn op in (self) -> yield *i32 { yield &self.a }
}

fn values(v: VPair) -> i32 {
    var s = 0
    for const x in v {
        s += x
    }

    for x in v {
        s += x
    }

    return s
}

fn pointers(v: PPair) -> i32 {
    var s = 0
    for const x in v {
        s += x
    }

    for const *x in v {
        s += *x
    }

    for *x in v {
        *x = 3
    }

    return s
}

fn tuples(v: TPair) -> i32 {
    var s = 0
    for (const a, b) in v {
        s += a + b
    }

    for (const a, const b) in v {
        s += a + b
    }

    return s
}

fn no_const_form(v: VOnly, p: POnly) -> i32 {
    var s = 0
    // CHECK: op_in_const_binder.k:[[@LINE+1]]:15: error [SC298E]: 'for const x' does not bind what 'op in (self)' yields: 'i32' binds only 'for x'; 'VOnly' declares no 'op in (const self)'
    for const x in v {
        s += x
    }

    // CHECK: op_in_const_binder.k:[[@LINE+1]]:15: error [SC298E]: 'for const *x' does not bind what 'op in (self)' yields: '*i32' binds 'for x' or 'for *x'; 'POnly' declares no 'op in (const self)'
    for const *x in p {
        s += *x
    }

    return s
}

fn mixed(t: PTuple) -> i32 {
    var s = 0
    for (const a, const *b) in t {
        s += a + *b
    }

    // A `*b` beside a `const` binder keeps `op in (self)`, where a `*i32`
    // element takes no `const`.
    // CHECK: op_in_const_binder.k:[[@LINE+2]]:10: error [SC298E]: the binder 'const a' does not bind what 'op in (self)' yields: '*i32' binds 'for a' or 'for *a'; a '*' binder beside it keeps the loop on 'op in (self)'
    // CHECK-NEXT: fix-it:"{{.*}}op_in_const_binder.k":{[[@LINE+1]]:10-[[@LINE+1]]:17}:"var a"
    for (const a, *b) in t {
        *b = a
    }

    return s
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
