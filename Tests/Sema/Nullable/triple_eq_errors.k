// G7 (Compiler/Sema/NULLABLE.md 2.3): what `===` refuses, and what it
// accepts without a check. Accepted: two Maybe `Pt?` from calls compared
// through Pt's own `op ==` with no "may be null" error (the `==` runs on
// the unwrapped values only after both tests); `===` narrows both places
// in its true branch and nothing in its false one. Refused: no nullable
// operand (two values, two plain pointers); `x === null` (never true;
// fix-it writes the null test); a nullable pointer against a non-pointer;
// a record with no `op ==`; a nullable RAW
// pointer outside `unsafe` (`===` would dereference it).

struct Pt {
    var x: i32
    fn op ==(self, o: Pt) -> bool { return self.x == o.x }
}
struct Bare { var x: i32 }

fn mk() -> Pt? { return null }
fn num() -> i32? { return null }

fn main() -> i32 {
    var p? = mk()
    var q? = mk()
    var ok1 = p === q
    var ok2 = mk() === mk()
    var a? = num()
    var b? = num()
    if a === b { var s = a + b }
    else { var t = a + 1 }

    var x = 3
    var y = 3
    var *px = &x
    var *py = &y
    var e1 = x === y
    var e2 = px === py
    var e3 = a === null
    var e4 = null === a
    var *pa? = px
    var e5 = pa === a
    var u? = Bare{ x: 1 }
    var e6 = u === u
    var raw: (unsafe *i32)? = unsafe &x
    var e8 = raw === raw
    unsafe { var ok3 = raw === raw }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:28:20: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:34:14: error [SC034E]: '===' needs a nullable operand; 'i32' and 'i32' are not nullable
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:35:14: error [SC034E]: '===' needs a nullable operand; '*i32' and '*i32' are not nullable
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:36:14: error [SC001E]: '===' with 'null' is never true: '===' holds only when both sides have a value
// DIAG: fix-it:{{.*}}:{36:14-36:24}:"!a?"
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:37:14: error [SC001E]: '===' with 'null' is never true
// DIAG: fix-it:{{.*}}:{37:14-37:24}:"!a?"
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:39:14: error [SC033E]: '===' operands '*i32?' and 'i32?' do not unify: on a nullable pointer '===' compares what it points to, so the other side must be a pointer too
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:41:14: error [SC066E]: '===' compares the values with their 'op ==', and 'Bare' has none
// DIAG-NOT: error [
// DIAG: triple_eq_errors.k:43:14: error [SC001E]: '===' on 'unsafe *i32?' and 'unsafe *i32?' dereferences a raw pointer, which requires an unsafe context
// DIAG-NOT: error [

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: ok1 : bool
// SEMA-DAG: ok2 : bool
// SEMA-DAG: ok3 : bool
// SEMA-DAG: s : i32
