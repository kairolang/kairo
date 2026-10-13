ffi "c++" import "<mutex>";
class Unique {
    var n: i32;
    @move fn Unique(self, other: Self) = default;
}
class OwnsInt {
    var n: i32;
    fn op delete(self) { }                  // expect: warning SC060W -- every field copies, so the class silently does
}
class OwnsUnique {
    var u: Unique;
    fn op delete(self) { }                  // expect: clean -- a move-only field makes it MOVE
}
class OwnsMutex {
    var m: cxx::std::mutex;
    fn op delete(self) { }                  // expect: clean -- std::mutex makes it NON_TRANSFER
}
class <T> OwnsT {
    var v: T;
    fn op delete(self) { }                  // expect: clean -- T decides, per instance
}

// --- lit wiring -----------------------------------------------------------
// Lifecycle rule 4: a custom destructor with no transfer constructor warns
// only when the category the fields derive is COPY, the one case where C++
// generates a copy nobody asked for. A move-only or non-transferable field
// already keeps the copy from existing, and a dependent field leaves the
// category to the instance, so neither warns.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:      custom_dtor_category.k:8:{{[0-9]+}}: warning [SC060W]: 'OwnsInt' has a custom destructor but no '@copy' or '@move' transfer constructor; it is implicitly copyable
// DIAG-NEXT: custom_dtor_category.k:8:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: declare it move-only: '@move fn OwnsInt(self, other: Self) = default'
// DIAG-NEXT: custom_dtor_category.k:8:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: or make it non-transferable: '@copy fn OwnsInt(self, const other: Self) = delete'
// DIAG-NOT:  {{error|warning}} [
