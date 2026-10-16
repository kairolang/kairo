// A standalone `finally` is the destructor of a local declared where it
// stands (control-flow.md): it runs when its BLOCK ends, on every exit, in
// reverse declaration order with the block's other locals, and reads its
// captures at exit, not at the `finally`. Each case appends digits to
// `trace`, so a body run twice, never, or out of order is a missing bit.

var trace: i64 = 0
fn mark(d: i64) { trace = trace * 10 + d }
fn reset() { trace = 0 }

class Tracer {
    pub var id: i64
    pub fn Tracer(self, id: i64) { self.id = id }
    @copy fn Tracer(self, const other: Self) = delete
    fn op delete(self) { mark(self.id) }
}

fn lifo() -> bool {
    reset()
    {
        var a = Tracer(1)
        finally { mark(2) }
        var b = Tracer(3)
        finally { mark(4) }
    }
    return trace == 4321
}

fn reads_at_exit() -> bool {
    reset()
    {
        var n: i64 = 1
        finally { mark(n) }
        n = 7
    }
    return trace == 7
}

fn writes_through() -> bool {
    var n: i64 = 0
    { finally { n = 5 } }
    return n == 5
}

fn early(flag: bool) -> i64 {
    reset()
    finally { mark(9) }
    if flag { return 1 }
    mark(8)
    return 0
}

fn early_return() -> bool {
    var a = (early(true) == 1) && (trace == 9)
    var b = (early(false) == 0) && (trace == 89)
    return a && b
}

fn per_iteration() -> bool {
    reset()
    var items: [i64; 3] = [1, 2, 3]
    for x in items {
        finally { mark(x) }
        if x == 2 { continue }
        mark(0)
    }
    return trace == 1203
}

fn reached(flag: bool) -> i64 {
    reset()
    {
        if flag {
            finally { mark(1) }
            mark(2)
        }
        mark(3)
    }
    return trace
}

fn only_if_reached() -> bool {
    return (reached(true) == 213) && (reached(false) == 3)
}

class Counter {
    pub var live: i64
    pub fn Counter(self) { self.live = 0 }
    pub fn work(self, n: i64) {
        self.live += n
        finally { self.live -= n }
        mark(self.live)
    }
}

fn self_capture() -> bool {
    reset()
    var c = Counter()
    c.work(4)
    return (trace == 4) && (c.live == 0)
}

fn nested() -> bool {
    reset()
    {
        var n: i64 = 1
        finally {
            mark(n)
            finally { mark(n + 1) }
            mark(n + 2)
        }
        n = 4
    }
    return trace == 465
}

fn main() -> i32 {
    var r = 0
    if lifo()            { r += 1 }
    if reads_at_exit()   { r += 2 }
    if writes_through()  { r += 4 }
    if early_return()    { r += 8 }
    if per_iteration()   { r += 16 }
    if only_if_reached() { r += 32 }
    if self_capture()    { r += 64 }
    if nested()          { r += 128 }
    return r                                    // 255
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// The guard is a local struct with pointer fields and an in-class
// destructor; the local is aggregate-initialized from the captures'
// addresses, `self` as the pointer it is.
// CXX: struct __kairo_Fin{{[0-9]+}} {
// CXX: ~__kairo_Fin{{[0-9]+}}()
// CXX: __kairo_owner = this
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NOFWD
// NOFWD-NOT: {{^ *}}struct __kairo_Fin{{[0-9]+}};

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 255
