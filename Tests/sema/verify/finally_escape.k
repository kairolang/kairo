// Nothing may leave a finally body: it is a destructor body.

fn f(x: i32) panic -> i32 {
    var n = 0
    finally {
        if x == 0 { return 1 }
        if x == 1 { break }
        if x == 2 { continue }
        if x == 3 { panic std::Error::Runtime("no") }
    }
    return n
}

fn g() -> yield i32 {
    finally { yield 1 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
// CHECK: finally_escape.k:6:21: error [SC014E]: `return`
// CHECK: finally_escape.k:7:21: error [SC014E]: `break`
// CHECK: finally_escape.k:8:21: error [SC014E]: `continue`
// CHECK: finally_escape.k:9:21: error [SC014E]: `panic`
// CHECK: finally_escape.k:15:15: error [SC014E]: `yield`
// CHECK-NOT: error
