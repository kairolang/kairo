ffi "c++" import "<mutex>";
class Guard {
    var m: cxx::std::mutex;
    @copy
    fn Guard(self, const other: Self) { }
}
class HoldsGuard {
    var g: Guard;
    @copy
    fn HoldsGuard(self, const other: Self) = default   // expect: clean -- Guard copies by its own body
}
class ImplGuard { var g: Guard; }
class Mover {
    var m: cxx::std::mutex;
    @move
    fn Mover(self, other: Self) { }
}
class HoldsMover { var v: Mover; }
class <T> BoxCopy {
    var v: T;
    @copy
    fn BoxCopy(self, const other: Self) { }
}
fn sink_g(@move g: Guard) { }
fn sink_m(@move m: Mover) { }
fn f(g: Guard, m: Mover) {
    sink_g(g);                              // expect: clean -- a copy is a valid move
    sink_m(m);                              // expect: clean
}

// --- lit wiring -----------------------------------------------------------
// A transfer constructor with a body decides copyable / movable by itself:
// the body does whatever it does, so a std::mutex field cannot take it away.
// A hand-written @copy is copyable and movable, a hand-written @move is
// movable only. Fields decide only for `= default` and for a class with no
// transfer constructor.
//
// The facts row has no copyable column, and a declared category already
// followed the declaration, so Guard and Mover read COPY / MOVE either way.
// The bits show through what reads them: SC129E on HoldsGuard, SC051E on the
// two moves, and the category a class with no transfer constructor derives
// from its field (ImplGuard, HoldsMover). BoxCopy no longer waits for T.
// Triviality still folds the fields in, and a user body is never trivial.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: {{error|warning}} [
//
// SEMA:      lifecycle Guard: category=COPY trivial_copy=0 trivial_dtor={{[01]}} destructible=1
// SEMA-NEXT: lifecycle HoldsGuard: category=COPY trivial_copy=0 trivial_dtor={{[01]}} destructible=1
// SEMA-NEXT: lifecycle ImplGuard: category=COPY trivial_copy=0 trivial_dtor={{[01]}} destructible=1
// SEMA-NEXT: lifecycle Mover: category=MOVE trivial_copy=0 trivial_dtor={{[01]}} destructible=1
// SEMA-NEXT: lifecycle HoldsMover: category=MOVE trivial_copy=0 trivial_dtor={{[01]}} destructible=1
// SEMA-NEXT: lifecycle BoxCopy: category=COPY trivial_copy=0 trivial_dtor=? destructible=?
