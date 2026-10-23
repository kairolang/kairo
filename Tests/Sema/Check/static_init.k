// A static field's initializer runs once, for no object: it may read other
// statics and no instance field. A static with no initializer is defined
// `T R::s{}`, so its type needs a default, as a `var x: T` does.

class S {
    pub static a: i32 = 4
    pub static b: i32 = a + 1
    pub static c: f64 = 1.5
    pub static none: i32
    pub var inst: i32 = 2
    pub static bad: i32 = inst + 1
// DIAG: static_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: the initializer of static field 'bad' reads instance field 'inst'; a static belongs to no object
    pub static flag: bool
// DIAG: static_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: static field 'flag' is declared without an initializer, and 'bool' has no zero state: a default would have to guess true or false; Kairo has no uninitialized variables
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
