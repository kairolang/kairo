class ScopeLock {
    fn ScopeLock(self) = default
    @copy
    fn ScopeLock(self, const other: Self) = delete
    @move
    fn ScopeLock(self, other: Self) = delete   // expect: clean -- X(X&&) beside X(const X&)
    fn op delete(self) { }
}
class TwoCopies {
    var n: i32;
    @copy
    fn TwoCopies(self, const other: Self) = default
    @copy
    fn TwoCopies(self, const other: Self) = default   // expect: error SC057E -- a second transfer constructor
}
class ConstAndNot {
    var n: i32;
    @copy
    fn ConstAndNot(self, const other: Self) = default
    @copy
    fn ConstAndNot(self, other: Self) = default       // expect: error SC057E -- X(X&) beside X(const X&)
}

// --- lit wiring -----------------------------------------------------------
// The NON_TRANSFER declaration: a deleted `@copy` and a deleted `@move`
// constructor. Both write `other` bare, and redeclaration merging runs before
// ClassLifecycle stamps the parameter's mode, so the transfer marker is the
// only thing that makes them two constructors -- C++ X(const X&) and X(X&&).
// Two `@copy` constructors are never merged as one member either: whether
// they repeat one signature or differ only in `const` on `other` (C++ X(X&)
// beside X(const X&), which a signature cannot tell apart), the error is the
// one-transfer-constructor rule, not a redeclaration.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT:  non_transfer_decl.k:6:{{[0-9]+}}: error
// DIAG:      non_transfer_decl.k:14:{{[0-9]+}}: error [SC057E]: 'TwoCopies' declares more than one '@copy' transfer constructor; a class has exactly one transfer constructor
// DIAG-NEXT: non_transfer_decl.k:12:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: the other transfer constructor is here
// DIAG-NEXT: non_transfer_decl.k:21:{{[0-9]+}}: error [SC057E]: 'ConstAndNot' declares more than one '@copy' transfer constructor
// DIAG-NEXT: non_transfer_decl.k:19:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: the other transfer constructor is here
// DIAG-NOT:  {{error|warning}} [
//
// SEMA: lifecycle ScopeLock: category=NON_TRANSFER trivial_copy=0 trivial_dtor=0 destructible=1
