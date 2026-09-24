// The operator rules, one declaration or use per rule. Each is X's or
// OperatorSignatureCheck's error; none reaches a lowering. Every EmitIR
// record-operand ICE is unreachable because the shape that would reach it is
// rejected here first.

struct V {
    var x: i32
    fn op +(self, o: V) -> V { return V{ x: self.x + o.x } }
    fn op +=(self, o: V) { self.x = self.x + o.x }              // both halves of a pair
    fn op ===(self, o: V) -> bool { return self.x == o.x }      // not overloadable
    fn op =(self, o: V) { }                                     // not overloadable
    fn op -(self, o: V, k: i32 = 0) -> V { return o }           // a default on an operator
    fn op <(self, o: V) -> i32 { return 0 }                     // a comparison returning i32
    fn op l++(self) -> V { return V{ x: self.x + 1 } }
}

struct U {
    var x: i32
    fn op -=(self, o: U) -> U { return o }                      // a compound assignment with a result
}

struct W {
    var x: i32
}

extend V {
    fn op as(self) -> i32 { return self.x }                     // member-only, in an extension
}

fn t(v: V, w: W, p: *i32, q: *i32, n: i32) {
    var a = w == w          // no op == on a record
    var b = n === n         // === on non-nullables
    var c = p === q         // === on non-nullable pointers
    var d = v++             // only op l++ is declared
    var e = 2 in v          // no op in
    var f = 2.0 ^^ 0.5      // a real exponent
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: error [SC001E]: 'op +=' and 'op +' are both declared; a type declares one of the pair and the other is derived from it
// DIAG: error [SC001E]: '===' is not overloadable
// DIAG: error [SC001E]: '=' is not overloadable
// DIAG: error [SC001E]: 'op -' takes no default arguments
// DIAG: error [SC001E]: 'op <' must return 'bool'
// DIAG: error [SC001E]: 'op -=' returns nothing
// DIAG: error [SC001E]: 'op as' cannot be declared in an extension
// DIAG: error [SC001E]: no 'op ==' on 'W'
// DIAG: error [SC001E]: '===' needs a nullable operand; 'i32' and 'i32' are not nullable
// DIAG: error [SC001E]: '===' needs a nullable operand; '*i32' and '*i32' are not nullable
// DIAG: error [SC001E]: no 'op r++' on 'V'
// DIAG: error [SC001E]: 'in' needs an 'op in' on 'V' taking a 'i32'
// DIAG: error [SC001E]: the exponent of '^^' must be an integer, not 'f64'
