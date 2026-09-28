class Base {
    @copy fn Base(self, other: Self) = delete
    fn op delete(self) { }
}
class Derived derives Base {                // expect: error class 'Derived' has a non-trivial destructor, but its base 'Base' does not have a virtual destructor
    @copy fn Derived(self, other: Self) = delete
    fn op delete(self) { }
}
class VBase {
    @copy fn VBase(self, other: Self) = delete
    virtual fn op delete(self) { }
}
class VDerived derives VBase {              // expect: clean
    @copy fn VDerived(self, other: Self) = delete
    override fn op delete(self) { }
}
class Plain derives Base {                  // expect: clean -- trivial derived dtor
    @copy fn Plain(self, other: Self) = delete
}
class Holder derives Base {                 // expect: error -- a non-trivial field makes the derived dtor non-trivial
    @copy fn Holder(self, other: Self) = delete
    var v: [i32];
}
class Deep derives VDerived {               // expect: clean -- virtual inherited through VDerived
    @copy fn Deep(self, other: Self) = delete
    fn op delete(self) { }
}

// --- lit wiring -----------------------------------------------------------
// ClassLifecycle's virtual-destructor rule. Every class declares its copy
// constructor `= delete`, so lifecycle rule 4 (custom destructor, implicit
// copy) is silent and the FULL diagnostic set is asserted: a wrong warning
// fails this file as surely as a wrong error. All are category Copy, so
// rule 5 (base compatibility) is silent too.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:     virtual_dtor.k:5:{{[0-9]+}}: error [SC056E]: class 'Derived' has a non-trivial destructor, but its base 'Base' does not have a virtual destructor
// DIAG-NOT: {{error|warning}} [
// DIAG:     virtual_dtor.k:20:{{[0-9]+}}: error [SC056E]: class 'Holder'
// DIAG-NOT: {{error|warning}} [
