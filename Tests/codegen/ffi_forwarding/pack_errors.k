// A pack pattern still binds by its reference kind: `Ts&...` takes only
// lvalues, as one `T&` parameter would, so a literal or a temporary is
// refused at the call instead of reaching clang.

ffi "c++" import "fwd.h"

fn main() -> i32 {
    var a = 1
    bump_all(a, 2)
    return a
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:9:5: error [SC063E]: no matching overload for call to 'bump_all'
// DIAG-NEXT: {{.*}}/fwd.h:29:1: note [I900N]: candidate not viable: expects 0 argument(s), 2 given
// DIAG-NEXT: {{.*}}/fwd.h:30:1: note [I900N]: candidate not viable: cannot convert argument of type '<literal>' to parameter 'rest' of type 'Rest&'
// END-GENERATED-CHECKS(DIAG)
