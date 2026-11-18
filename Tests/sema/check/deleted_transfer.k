class NoCopy {
    var n: i32;
    @copy
    fn NoCopy(self, const other: Self) = delete
}
class NoMove {
    var n: i32;
    @move
    fn NoMove(self, other: Self) = delete
}
class Neither {
    var n: i32;
    @copy
    fn Neither(self, const other: Self) = delete
    @move
    fn Neither(self, other: Self) = delete
}
class HoldsNoCopy { var c: NoCopy; }
enum WrapsNoMove { Has { m: NoMove }, Empty }

// --- lit wiring -----------------------------------------------------------
// One deleted transfer constructor is enough to make a class NON_TRANSFER,
// because that is what C++ makes of it: a user-declared copy constructor,
// deleted or not, suppresses the implicit move, and a declared move makes
// the implicit copy deleted. So `@copy = delete` alone, `@move = delete`
// alone and both together all transfer neither way, and a class or ADT that
// holds one derives NON_TRANSFER from it.
//
// A deleted transfer is never trivially copyable: there is no transfer left
// to be trivial, and the derived `op =` is deleted with it.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: {{error|warning}} [
//
// SEMA:      lifecycle NoCopy: category=NON_TRANSFER trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle NoMove: category=NON_TRANSFER trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle Neither: category=NON_TRANSFER trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle HoldsNoCopy: category=NON_TRANSFER trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle WrapsNoMove: category=NON_TRANSFER trivial_copy=0 trivial_dtor=1 destructible=1
