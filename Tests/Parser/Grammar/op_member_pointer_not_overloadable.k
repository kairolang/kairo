// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// `.*` and `->*` are not overloadable. C++ forbids `operator.*` outright, so
// there is nothing for `op .*` to lower to, and `operator->*` is a DSL
// curiosity no smart pointer defines. The declaration parser is the gate:
// neither spelling reaches Sema. `->` beside them still parses, which is
// what keeps this from passing on a parser that rejects every operator.

struct P {
    var x: i32
    pub fn op .* (self, i: usize) -> *i32 { return &self.x }
    pub fn op ->* (self, i: usize) -> *i32 { return &self.x }
    pub fn op -> (self) -> *i32 { return &self.x }
}

// DIAG:     op_member_pointer_not_overloadable.k:11:{{[0-9]+}}: error [S045E]: given operator is not valid to overload
// DIAG:     op_member_pointer_not_overloadable.k:12:{{[0-9]+}}: error [S045E]: given operator is not valid to overload
// DIAG-NOT: op_member_pointer_not_overloadable.k:13:
