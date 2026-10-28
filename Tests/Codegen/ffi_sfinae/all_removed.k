// When substitution removes EVERY candidate the call is SC063E, each
// candidate noted with clang's own reason -- a failed enable_if
// requirement, an expression that does not compile (decltype), an
// unsatisfied requires-clause; with only one candidate, the same error
// with its single note. A deduction Kairo already refuses keeps its own
// reason (the `req` call): clang only adds substitution verdicts.

ffi "c++" import "sfinae.h"

fn main() -> i32 {
    var p = Pair(1, 2)
    var a = on_default(p)
    var b = twice(p)
    var c = req(p, 1)
    var d = has_size(p)
    var e = only_int(p)
    return a + b.a + c + d + e
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:12:13: error [SC063E]: no matching overload for call to 'on_default'
// DIAG-NEXT: {{.*}}/sfinae.h:20:1: note [I900N]: candidate not viable: template ignored: requirement 'std::is_integral_v<Pair>' was not satisfied
// DIAG-NEXT: {{.*}}/sfinae.h:22:1: note [I900N]: candidate not viable: template ignored: requirement 'std::is_floating_point_v<Pair>' was not satisfied
// DIAG: {{.*}}:13:13: error [SC063E]: no matching overload for call to 'twice'
// DIAG-NEXT: {{.*}}/sfinae.h:77:1: note [I900N]: candidate not viable: template ignored: requirement 'std::is_integral_v<Pair>' was not satisfied
// DIAG: {{.*}}:14:13: error [SC063E]: no matching overload for call to 'req'
// DIAG-NEXT: {{.*}}/sfinae.h:62:1: note [I900N]: candidate not viable: expects 1 argument(s), 2 given
// DIAG-NEXT: {{.*}}/sfinae.h:64:1: note [I900N]: candidate not viable: expects 1 argument(s), 2 given
// DIAG: {{.*}}:15:13: error [SC063E]: no matching overload for call to 'has_size'
// DIAG-NEXT: {{.*}}/sfinae.h:44:1: note [I900N]: candidate not viable: template ignored: substitution failure: no member named 'size' in 'Pair'
// DIAG-NEXT: {{.*}}/sfinae.h:46:1: note [I900N]: candidate not viable: template ignored: substitution failure: invalid operands to binary expression ('Pair' and 'int')
// DIAG: {{.*}}:16:13: error [SC063E]: no matching overload for call to 'only_int'
// DIAG-NEXT: {{.*}}/sfinae.h:98:1: note [I900N]: candidate not viable: template ignored: its constraints are not satisfied
// END-GENERATED-CHECKS(DIAG)
