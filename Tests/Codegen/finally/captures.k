// What a `finally` body sees: every capture is by address, so the body
// reads the value at exit and writes the variable itself -- a local, a
// parameter, a `const` one, the enclosing `self` (const or not) and its
// fields, a pointer's target. A global is named, not captured. The body
// may declare its own locals, shadow a capture after reading it, run its
// own loops with break and continue, and nest further `finally`s that see
// the same captures. A `return x` computes its value BEFORE the guard
// runs, so a write to `x` in the body does not change what is returned.

var trace: i64 = 0
fn mark(d: i64) { trace = trace * 10 + d }
fn reset() { trace = 0 }

fn bump(p: i64) -> i64 {
    { finally { p = p + 1 } }
    return p
}
fn param_write() -> bool { return bump(41) == 42 }

fn ret(write: bool) -> i64 {
    var x: i64 = 1
    finally { if write { x = 2 } }
    return x
}
fn retval_fixed() -> bool { return (ret(true) == 1) && (ret(false) == 1) }

// Two guards on one variable each read its final value.
fn same_var() -> bool {
    reset()
    {
        var n: i64 = 1
        finally { mark(n) }
        n = 2
        finally { mark(n) }
        n = 3
    }
    return trace == 33
}

// The first `n` is the capture; the body's own `n` shadows it after.
fn shadow() -> bool {
    reset()
    var n: i64 = 1
    {
        finally { mark(n); var n: i64 = 5; mark(n) }
        n = 2
    }
    return trace == 25
}

fn consts(const c: i64) {
    const k: i64 = 3
    finally { mark(c); mark(k) }
}
fn const_capture() -> bool { reset(); consts(4); return trace == 43 }

fn incr(p: *i64) { finally { (*p) += 1 } }
fn through_pointer() -> bool {
    var x: i64 = 9
    incr(&x)
    incr(&x)
    return x == 11
}

class Probe {
    pub var v: i64
    pub fn Probe(self) {
        self.v = 1
        finally { self.v = 5; mark(7) }     // runs at the constructor's end
        mark(self.v)
    }
    pub fn get(const self) -> i64 { finally { mark(self.v) } return self.v }
}

fn in_ctor() -> bool {
    reset()
    var p = Probe()
    mark(p.v)
    return trace == 175
}

fn const_self() -> bool {
    reset()
    var p = Probe()
    reset()
    var g = p.get()
    return (g == 5) && (trace == 5)
}

class Dtor {
    pub var v: i64
    pub fn Dtor(self) { self.v = 3 }
    @copy fn Dtor(self, const other: Self) = delete
    fn op delete(self) {
        finally { mark(self.v) }
        mark(1)
    }
}

fn in_dtor() -> bool {
    reset()
    { var d = Dtor() }
    return trace == 13
}

// The guard record is local to the template, instantiated with it.
fn <T> gen(x: T, d: i64) -> T {
    var y = x
    finally { mark(d); y = x }
    return y
}
fn generic() -> bool {
    reset()
    var a = gen<i64>(4, 4)
    var b = gen<i32>(5, 5)
    return (a == 4) && (b == 5) && (trace == 45)
}

// Three levels: each inner guard is declared inside the outer body and
// runs at that body's end, and all of them see `n`.
fn deep() -> bool {
    reset()
    {
        var n: i64 = 1
        finally {
            finally {
                finally { mark(n) }
                mark(n + 1)
            }
            mark(n + 2)
        }
    }
    return trace == 321
}

// Loops inside a finally body are the body's own: break and continue
// there are legal and stay inside it.
fn body_loops() -> bool {
    reset()
    {
        finally {
            var i: i64 = 0
            while true { i += 1; if i == 3 { break } }
            for var j: i64 = 0; j < 5; ++j { if j == 1 { continue } if j == 3 { break } mark(j) }
            mark(i)
        }
    }
    return trace == 23
}

fn empty() -> bool {
    { finally { } }
    finally { }
    return true
}

// The exit code names the first case that failed; 0 is all of them passed.
fn main() -> i32 {
    if !param_write()     { return 1 }
    if !retval_fixed()    { return 2 }
    if !same_var()        { return 3 }
    if !shadow()          { return 4 }
    if !const_capture()   { return 5 }
    if !through_pointer() { return 6 }
    if !in_ctor()         { return 7 }
    if !const_self()      { return 8 }
    if !in_dtor()         { return 9 }
    if !generic()         { return 10 }
    if !deep()            { return 11 }
    if !body_loops()      { return 12 }
    if !empty()           { return 13 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The deliberate shadow in shadow() warns; nothing else may.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG:     captures.k:45:28: warning [R048W]: declaration of 'n' hides
// DIAG-NOT: {{error|warning}}

// The shape of the captures: pointer fields in first-use order, a `const`
// parameter as a pointer to const, the global named and never a field,
// `self` in a const method as a pointer to a const owner.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      void consts(const signed long c) {
// CXX:      struct __kairo_Fin{{[0-9]+}} {
// CXX-NEXT:   const signed long * c;
// CXX-NEXT:   const signed long * k;
// CXX-NEXT:   ~__kairo_Fin
// CXX:      get() const {
// CXX:      struct __kairo_Fin{{[0-9]+}} {
// CXX-NEXT:   const{{.*}}Probe * __kairo_owner;
// CXX-NEXT:   ~__kairo_Fin
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NOGLOBAL
// NOGLOBAL-NOT: {{\*}} trace;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
