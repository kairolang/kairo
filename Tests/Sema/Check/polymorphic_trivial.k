class Plain {
    var a: i32;
}
class Poly {
    var a: i32;
    virtual fn f(self) -> i32 { return self.a; }
}
class Over derives Poly {
    var b: i32;
    override fn f(self) -> i32 { return self.b; }
}
class Inherits derives Poly {
    var b: i32;
}
class VBase derives virtual Plain {
    var b: i32;
}
class VDtor {
    var a: i32;
    virtual fn op delete(self) = default
}
class HoldsPoly { var p: Poly; }
enum PolyPayload { Has { p: Poly }, Empty }

// --- lit wiring -----------------------------------------------------------
// A polymorphic record is never trivially copyable: a copy has to set the
// vptr, or the virtual-base offset, instead of copying bytes. Only its
// destructor triviality stays the components' -- a virtual method or a
// virtual base leaves the destructor trivial; a virtual destructor does not.
//
//   Plain       the control: trivially everything.
//   Poly        a virtual method of its own.
//   Over        an override is virtual too.
//   Inherits    nothing virtual of its own; the base's vptr is in it all the
//               same, through the base fold.
//   VBase       `derives virtual`.
//   VDtor       a virtual destructor, defaulted: neither bit is trivial.
//   HoldsPoly   a by-value polymorphic field.
//   PolyPayload an ADT over a polymorphic payload.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: {{error|warning}} [
//
// SEMA:      lifecycle Plain: category=COPY trivial_copy=1 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle Poly: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle Over: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle Inherits: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle VBase: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle VDtor: category=COPY trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT: lifecycle HoldsPoly: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT: lifecycle PolyPayload: category=COPY trivial_copy=0 trivial_dtor=1 destructible=1
