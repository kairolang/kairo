class C {
    fn a(@inout self) { }                   // expect: error 'self' takes no passing mode
    fn b(@move self) { }                    // expect: error 'self' takes no passing mode
    fn c(const @inout x: i32) { }           // expect: error 'const' and '@inout' contradict
    fn d(const @move x: i32) { }            // expect: error 'const' cannot be combined with '@move'
}

// --- lit wiring -----------------------------------------------------------
// KAIRO-ONLY: the receiver is already a reference parameter, and `const`
// contradicts both modes.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:     receiver_and_const.k:2:{{[0-9]+}}: error [{{[A-Z0-9]+}}]: {{.*}}'self' takes no passing mode
// DIAG:     receiver_and_const.k:3:{{[0-9]+}}: error [{{[A-Z0-9]+}}]: {{.*}}'self' takes no passing mode
// DIAG:     receiver_and_const.k:4:{{[0-9]+}}: error [{{[A-Z0-9]+}}]: {{.*}}'const' and '@inout' contradict
// DIAG:     receiver_and_const.k:5:{{[0-9]+}}: error [{{[A-Z0-9]+}}]: {{.*}}'const' cannot be combined with '@move'
// DIAG-NOT: error [
