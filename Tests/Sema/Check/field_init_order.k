// A field's default runs as a C++ default member initializer, in declaration
// order, so it may read a field declared before it and no other: a later
// field, or the field itself, is not built yet. A static field is no part of
// the object and may be read anywhere, and so is an eval field (a static,
// EVAL.md 1.2). An array field's list literal is lowered element by element;
// a static array's default has no lowering yet and is gated, and so is a
// sibling read in a generic record's default. A static's default is lowered
// (static_init.k), and so is an eval field's.

class Fwd {
    pub var a: i32 = b + 1
// DIAG: field_init_order.k:[[@LINE-1]]:22: error [{{SC0*1E}}]: the default of 'a' reads 'b', which is declared after it
    pub var b: i32 = 1
// DIAG: field_init_order.k:[[@LINE-1]]:9: note [{{[A-Z0-9]+}}]: 'b' is declared here; defaults run in declaration order, so it is not built yet when 'a' is
}

class Own {
    pub var a: i32 = a * 2
// DIAG: field_init_order.k:[[@LINE-1]]:22: error [{{SC0*1E}}]: the default of 'a' reads 'a' itself, which it is still building
}

class Back {
    pub var a: i32 = 2
    pub var b: i32 = a + 1
    pub var c: i32 = a + b
}

class <T> GenBack {
    pub var a: i32 = 2
    pub var b: i32 = a + 1
// DIAG: field_init_order.k:[[@LINE-1]]:22: error [SC116E]: reading another field in the default of a generic record's field is not yet supported
    pub var v: T = T()
}

class Gated {
    pub static n: i32 = 4
    pub eval e: i32 = 5
    pub var arr: [i32; 2] = [1, 2]
    pub static sarr: [i32; 2] = [1, 2]
// DIAG: field_init_order.k:[[@LINE-1]]:33: error [SC116E]: an initializer on a static array-typed field is not yet supported
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
