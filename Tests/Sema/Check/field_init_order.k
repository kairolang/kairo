// A field's default runs as a C++ default member initializer, in declaration
// order, so it may read a field declared before it and no other: a later
// field, or the field itself, is not built yet. A static field is no part of
// the object and may be read anywhere. Defaults on static, eval and
// array-typed fields have no lowering yet and are gated, and so is a sibling
// read in a generic record's default.

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
// DIAG: field_init_order.k:[[@LINE-1]]:25: error [SC116E]: an initializer on a static field is not yet supported
    pub eval e: i32 = 5
// DIAG: field_init_order.k:[[@LINE-1]]:23: error [SC116E]: an initializer on an eval field is not yet supported
    pub var arr: [i32; 2] = [1, 2]
// DIAG: field_init_order.k:[[@LINE-1]]:29: error [SC116E]: an initializer on an array-typed field is not yet supported
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
