// Assignment is derived from the transfer constructor, and some records
// derive none: a polymorphic class whose transfer constructor has a body
// (its `op =` would destroy the value and rebuild it in place, which a base
// or a derived object does not survive), a class whose transfer
// constructor is deleted, and a class that assigns member by member over a
// member that cannot be assigned. Assigning one is an error here rather
// than in C++. A defaulted transfer constructor, or none at all, assigns
// member by member, which a polymorphic class allows.

class P {
    pub var v: i32
    pub fn P(self, v: i32) { self.v = v }
    @copy
    fn P(self, const other: Self) { self.v = other.v }
    virtual fn get(const self) -> i32 { return self.v }
}

class Q {
    pub var v: i32
    pub fn Q(self, v: i32) { self.v = v }
    @copy
    fn Q(self, const other: Self) = default
    virtual fn get(const self) -> i32 { return self.v }
}

class R {
    pub var v: i32
    pub fn R(self, v: i32) { self.v = v }
    virtual fn get(const self) -> i32 { return self.v }
}

class N {
    pub var v: i32
    pub fn N(self, v: i32) { self.v = v }
    @copy
    fn N(self, const other: Self) = delete
    @move
    fn N(self, other: Self) = delete
}

class H {
    pub var p: P
    @copy
    fn H(self, const other: Self) = default
}

fn f(a: P, b: Q, c: R, h: H, k: H) {
    var p = a
    p = a
    var q = b
    q = b
    var r = c
    r = c
    var n = N(1)
    var m = N(2)
    n = m
    var x = h
    x = k
}

class W {
    pub var p: P
    pub fn set(self, o: P) { self.p = o }
}

// --- lit wiring -----------------------------------------------------------
// The last line is a member assigned inside a method, reported once.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     assign_deleted.k:49:{{[0-9]+}}: error [SC071E]: cannot assign a 'P': it is polymorphic, and assigning it would destroy it and rebuild it in place through its transfer constructor
// DIAG:     assign_deleted.k:10:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: type declared here
// DIAG:     note [{{[A-Z0-9]+}}]: polymorphic classes cannot be assigned; construct a new value
// DIAG-NOT: error [
// DIAG:     assign_deleted.k:56:{{[0-9]+}}: error [SC071E]: cannot assign a 'N': its transfer constructor is deleted
// DIAG-NOT: error [
// DIAG:     assign_deleted.k:58:{{[0-9]+}}: error [SC071E]: cannot assign a 'H': its field 'p' cannot be assigned
// DIAG-NOT: error [
// DIAG:     assign_deleted.k:63:{{[0-9]+}}: error [SC071E]: cannot assign a 'P': it is polymorphic
// DIAG-NOT: {{error|warning}} [
