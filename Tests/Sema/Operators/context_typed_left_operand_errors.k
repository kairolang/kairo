// The errors a context-typed LEFT operand gets now that it is typed against
// the right one (context_typed_left_operand.k): the right operand's type is
// its expected type, so a literal that does not fit it is SC075E at the
// literal, and a `.V` the right operand's enum lacks is SC123E naming that
// enum -- the same errors the mirrored `b + 300` / `d == .Up` get.
//
// Two context-typed operands give each other nothing: the left keeps its
// default (or SC123E), and the right is typed against that, as before.
//
// A generic right operand is no type a literal can take: the literal keeps
// its default and the operator follows the bound rules a `t` on the right
// always had (MONO.md D0: refused on a bounds-checked parameter). A `.V`
// typed against an unbounded `T` is unknown, as `t == .V` is.

enum Dir { North, South }
enum Lvl { Lo, Hi }

fn <T> lit_left(t: T) -> bool = 1 == t
fn <T> dot_left(t: T) -> bool = .North == t
fn <T> dot_right(t: T) -> bool = t == .North

fn main() -> i32 {
    var b: u8 = 3
    var s: i8 = 1
    var d = Dir::North
    var big = 300 + b
    var bigshl = 256 << b
    var negu = -1 + b
    var under = -129 < s
    var mirror = b + 300
    var nodot = .Up == d
    var other = .Lo == d
    var both = .North == .South
    var litdot = 1 == .North
    var arith = .North + d
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:18:33: error [R051E]: '==' on 'T' needs a bound that declares 'op =='
// DIAG-NEXT: {{.*}}:18:5: note [R051N]: 'T' is declared with no bound
// DIAG: {{.*}}:26:15: error [SC075E]: literal '300' does not fit in 'u8'
// DIAG: {{.*}}:27:18: error [SC075E]: literal '256' does not fit in 'u8'
// DIAG: {{.*}}:28:17: error [SC075E]: literal '1' does not fit in 'u8'
// DIAG: {{.*}}:29:18: error [SC075E]: literal '129' does not fit in 'i8'
// DIAG: {{.*}}:30:22: error [SC075E]: literal '300' does not fit in 'u8'
// DIAG: {{.*}}:31:17: error [SC123E]: 'Dir' has no variant named 'Up'
// DIAG: {{.*}}:32:17: error [SC123E]: 'Dir' has no variant named 'Lo'
// DIAG: {{.*}}:33:16: error [SC123E]: '.North' names an enum variant, but nothing here gives it an enum type; write the enum's name before it
// DIAG: {{.*}}:33:26: error [SC123E]: '.South' names an enum variant, but nothing here gives it an enum type; write the enum's name before it
// DIAG: {{.*}}:34:23: error [SC123E]: '.North' names an enum variant, but the expected type is 'i32', not an enum
// DIAG: {{.*}}:35:17: error [SC066E]: no operator '+' for operands 'Dir' and 'Dir'
// END-GENERATED-CHECKS(DIAG)
