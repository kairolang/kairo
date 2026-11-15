// What a type's `op in` yields decides the binders a loop over it may
// write (SC298E for every other one):
//
//   (self)       -> yield T          for x
//   (const self) -> yield T          for x, for const x
//   (self)       -> yield *T         for x, for *x
//   (const self) -> yield *T         for x, for const x, for const *x
//   (self)       -> yield unsafe *T  for unsafe *x
//   (const self) -> yield unsafe *T  for unsafe *x, for const unsafe *x
//
// The loop takes `op in (const self)` over a const object and
// `op in (self)` over a mutable one. Each class below declares one form;
// `v` is a mutable object, `c` a const one.

class Val {
    var a: i32 = 1
    fn op in (self) -> yield i32 {
        yield self.a
    }
}

class CVal {
    var a: i32 = 1
    fn op in (const self) -> yield i32 {
        yield self.a
    }
}

class Ptr {
    var a: i32 = 1
    fn op in (self) -> yield *i32 {
        yield &self.a
    }
}

class CPtr {
    var a: i32 = 1
    fn op in (const self) -> yield *const i32 {
        yield &self.a
    }
}

class Raw {
    var a: i32 = 1
    fn op in (self) -> yield unsafe *i32 {
        unsafe {
            yield &self.a as unsafe *i32
        }
    }
}

class CRaw {
    var a: i32 = 1
    fn op in (const self) -> yield unsafe *const i32 {
        unsafe {
            yield &self.a as unsafe *const i32
        }
    }
}

class Pairs {
    var p: (i32, i32) = (1, 2)
    fn op in (self) -> yield (i32, i32) {
        yield self.p
    }
}

fn val(v: Val) -> i32 {
    var s = 0
    for x in v {
        s += x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:15: error [SC298E]: 'for const x' does not bind what 'op in (self)' yields: 'i32' binds only 'for x'
    for const x in v {
        s += x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+2]]:9: error [SC298E]: 'for *x' does not bind what 'op in (self)' yields: 'i32' binds only 'for x'; to bind a pointer to the element, declare 'op in (self) -> yield *i32'
    // CHECK-NEXT: fix-it:"{{.*}}op_in_binder_rule.k":{[[@LINE+1]]:9-[[@LINE+1]]:11}:"x"
    for *x in v {
        s += *x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for unsafe *x' does not bind
    for unsafe *x in v { }
    return s
}

fn cval(v: CVal, const c: CVal) -> i32 {
    var s = 0
    for x in v {
        s += x
    }

    for const x in v {
        s += x
    }

    for x in c {
        s += x
    }

    for const x in c {
        s += x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for *x' does not bind what 'op in (const self)' yields: 'i32' binds 'for x' or 'for const x'; to bind a pointer to the element, declare 'op in (const self) -> yield *const i32'
    for *x in c {
        s += *x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:15: error [SC298E]: 'for const *x' does not bind
    for const *x in v {
        s += *x
    }

    return s
}

fn ptr(v: Ptr) -> i32 {
    var s = 0
    for x in v {
        s += x
    }

    for *x in v {
        *x = 2
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:15: error [SC298E]: 'for const x' does not bind what 'op in (self)' yields: '*i32' binds 'for x' or 'for *x'
    for const x in v {
        s += x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:15: error [SC298E]: 'for const *x' does not bind what 'op in (self)' yields: '*i32' binds 'for x' or 'for *x'
    for const *x in v {
        s += *x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for unsafe *x' does not bind what 'op in (self)' yields: '*i32' binds 'for x' or 'for *x'
    for unsafe *x in v { }
    return s
}

fn cptr(v: CPtr, const c: CPtr) -> i32 {
    var s = 0
    for x in c {
        s += x
    }

    for const x in c {
        s += x
    }

    for const *x in c {
        s += *x
    }

    for const *x in v {
        s += *x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+2]]:9: error [SC298E]: 'for *x' does not bind what 'op in (const self)' yields: '*const i32' binds 'for x', 'for const x' or 'for const *x'; through 'const self' the element is read-only
    // CHECK-NEXT: fix-it:"{{.*}}op_in_binder_rule.k":{[[@LINE+1]]:9-[[@LINE+1]]:11}:"const *x"
    for *x in c {
        s += *x
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for unsafe *x' does not bind
    for unsafe *x in c { }
    return s
}

fn raw(v: Raw) -> i32 {
    var s = 0
    for unsafe *x in v {
        unsafe {
            s += *x
        }
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for x' does not bind what 'op in (self)' yields: 'unsafe *i32' binds only 'for unsafe *x'
    for x in v { }
    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for *x' does not bind what 'op in (self)' yields: 'unsafe *i32' binds only 'for unsafe *x'
    for *x in v { }
    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:15: error [SC298E]: 'for const unsafe *x' does not bind
    for const unsafe *x in v { }
    return s
}

fn craw(const c: CRaw) -> i32 {
    var s = 0
    for unsafe *x in c {
        unsafe {
            s += *x
        }
    }

    for const unsafe *x in c {
        unsafe {
            s += *x
        }
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for x' does not bind what 'op in (const self)' yields: 'unsafe *const i32' binds 'for unsafe *x' or 'for const unsafe *x'
    for x in c { }
    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:15: error [SC298E]: 'for const *x' does not bind
    for const *x in c { }
    return s
}

fn pairs(p: Pairs) -> i32 {
    var s = 0
    for (a, b) in p {
        s += a + b
    }

    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:13: error [SC298E]: the binder '*b' does not bind what 'op in (self)' yields: '(i32, i32)' binds only 'for b'
    for (a, *b) in p {
        s += a
    }

    for _ in p {
        s += 1
    }

    return s
}

// The form is what the declaration writes: a generic `-> yield T` yields
// values whatever `T` is, a pointer included.
class <T> Box {
    var a: T

    fn Box(self, a: T) { self.a = a }

    fn op in (self) -> yield T { yield self.a }
}

fn boxed(b: Box<*i32>) -> i32 {
    var s = 0
    for p in b { s += *p }
    // CHECK: op_in_binder_rule.k:[[@LINE+1]]:9: error [SC298E]: 'for *p' does not bind what 'op in (self)' yields: '*i32' binds only 'for p'
    for *p in b { }
    return s
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --check-prefix=NOTE
// NOTE: op_in_binder_rule.k:17:5: note [SC298N]: 'op in (self)' is declared here
