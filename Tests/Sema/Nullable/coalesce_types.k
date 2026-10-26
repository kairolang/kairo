// G8 (Compiler/Sema/NULLABLE.md 2.4): the type of `x ?? y` is the join of
// the arms of `if x? => x else y`. Each `t_*` initializes a `bool` from a
// `??` so the conversion error names the type the operator got:
//   - `i32? ?? i32` is `i32`; `i32? ?? i32?` is `i32?`; a chain `a ?? b ?? 4`
//     is `i32`;
//   - `(i32?)? ?? i32?` is `i32?` (the then-arm's own type), not `(i32?)?`;
//   - `i32? ?? i64?` is `i64?`;
//   - a generic `T? ?? T` is `T` with no instantiation;
// and the errors: a non-nullable left side warns (SC065W), operands with no
// common type are SC033E. `??` reads no value: `x ?? 0` on an unchecked `x`
// is fine, and is not a check (a read of `x` after it is still an error).
// The loop pre-scan knows `n() ?? 5` is a value: assigning it in a loop
// keeps a proven place proven at the head; `n() ?? n()` does not.

fn n() -> i32? { return null }
fn l() -> i64? { return null }
fn nn() -> (i32?)? { return null }

fn t_value(a: i32?)  { var r: bool = a ?? 5 }
fn t_both(a: i32?)   { var r: bool = a ?? n() }
fn t_chain(a: i32?)  { var r: bool = a ?? n() ?? 4 }
fn t_nested()        { var r: bool = nn() ?? n() }
fn t_widen(a: i32?)  { var r: bool = a ?? l() }
fn <T> t_generic(t: T?, d: T) -> T { return t ?? d }

fn t_plain(a: i32) -> i32 { return a ?? 3 }
fn t_mismatch(a: i32?) { var r = a ?? "no" }

fn t_no_check(a: i32?) -> i32 {
    var v = a ?? 0
    return v + a
}

fn ok_loop(k: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < k {
        r += x
        x = n() ?? 5
    }
    return r
}

fn bad_loop(k: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < k {
        r += x
        x = n() ?? n()
    }
    return r
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:17:18: warning [S055W]: nested nullable
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:19:38: error [SC028E]: cannot convert 'i32' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:20:38: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:21:38: error [SC028E]: cannot convert 'i32' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:22:38: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:23:38: error [SC028E]: cannot convert 'i64?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:26:36: warning [SC065W]: left operand of '??' has non-nullable type 'i32'; the right operand is never used
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:27:34: error [SC033E]: '??' operands 'i32?' and 'string' have no common type
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:31:16: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: coalesce_types.k:29:15: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: coalesce_types.k:48:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: coalesce_types.k:49:9: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
