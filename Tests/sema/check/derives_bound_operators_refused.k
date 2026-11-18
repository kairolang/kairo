// An operator a `derives` bound's base does not declare is refused at the
// definition, as one an interface bound does not declare is
// (opaque_param_ops.k): R025E naming what would grant it, never a deferral
// to clang at some instance. The base's table is the whole scope -- its own
// operators, its bases', its extensions' -- and nothing else: no free
// operator, no ADL, so `1 + t` (an `i32` has no `+` taking a T) is the
// right-operand error, and a free `op +` on Base, which takes Base by value
// and so cannot take a T without slicing it, is not consulted.
//
// A base operator whose parameter is the BASE by value does not take a T
// either: SC063E, the same refusal `Der == Der` gets on a concrete record.
//
// Under `: type` (-fduck-generics) the same bodies are C++'s to check:
// nothing is said.

class Base {
    pub var v: i32 = 0
    fn op == (self, o: Base) -> bool { return self.v == o.v; }
    fn op * (self, k: i32) -> i32 { return self.v * k; }
}
class Plain { pub var v: i32 = 0 }

fn op + (a: Base, k: i32) -> i32 { return a.v + k; }

fn <T derives Plain> eq(a: T, b: T) -> bool = a == b
fn <T derives Plain> ne(a: T, b: T) -> bool = a != b
fn <T derives Plain> lt(a: T, b: T) -> bool = a < b
fn <T derives Plain> neg(a: T) -> i32 = -a
fn <T derives Plain> idx(a: T) -> i32 = a[0]
fn <T derives Plain> power(a: T) -> i32 = a ^^ 2
fn <T derives Plain> bump(a: T) {
    var x = a
    x += 1
}
fn <T derives Plain> same(a: T?, b: T?) -> bool = a === b
fn <T derives Base> free_add(a: T) -> i32 = a + 1
fn <T derives Base> radd(a: T) -> i32 = 2 * a
fn <T derives Base> by_value(a: T, b: T) -> bool = a == b

// What the base does declare still binds.
fn <T derives Base> fine(a: T) -> i32 = a * 3

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// Left out of the copy: `a[0]`, which is SC103E on any `: type` parameter
// today (not this file's rule), and by_value, whose `op ==` the base DOES
// declare -- a bound still grants what it declares under `: type`, and
// that one cannot take a T.
// RUN: sed -e 's/fn <T derives/fn <T: type derives/' -e '/a\[0\]/d' -e '/by_value/d' %s > %t.k
// RUN: { %kairo %t.k --type-check-only -fduck-generics 2>&1 || true; } | %FileCheck %s --check-prefix=DUCK --allow-empty
// DUCK-NOT: error

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:25:47: error [R025E]: '==' on 'T' needs a bound that declares 'op =='; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:25:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:26:47: error [R025E]: '!=' on 'T' needs a bound that declares 'op !=' or 'op =='; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:26:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:27:47: error [R025E]: '<' on 'T' needs a bound that declares 'op <' or 'op <=>'; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:27:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:28:41: error [R025E]: '-' on 'T' needs a bound that declares 'op -'; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:28:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:29:41: error [SC103E]: 'T' has no subscript operator
// DIAG: {{.*}}:30:43: error [R025E]: '^^' on 'T' needs a bound that declares 'op ^^'; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:30:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:33:5: error [R025E]: '+=' on 'T' needs a bound that declares 'op +=' or 'op +'; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:31:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:35:51: error [R025E]: '===' on 'T?' compares the values with 'op ==', so it needs a bound on 'T' that declares 'op =='; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:35:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:36:45: error [R025E]: '+' on 'T' needs a bound that declares 'op +' or 'op +='; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:36:5: note [I900N]: 'T' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:37:41: error [SC066E]: no operator '*' for operands 'i32' and 'T': an operator a bound grants is its parameter's, on the left
// DIAG: {{.*}}:38:52: error [SC063E]: no matching overload for call to 'op =='
// DIAG-NEXT: {{.*}}:18:5: note [I900N]: candidate not viable: cannot convert argument of type 'T' to parameter 'o' of type 'Base'
// END-GENERATED-CHECKS(DIAG)
