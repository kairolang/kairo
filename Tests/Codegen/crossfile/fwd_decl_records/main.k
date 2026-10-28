import lib::*

// A struct and a union forward-declared in lib.k and defined later there,
// used by value from this TU.
fn main() -> i32 {
    var p = Payload{as_int: 7}
    var m = Message{kind: 1, data: unsafe &p}
    var r = Ring{n: 2}
    unsafe {
        return (m.data->as_int as i32) + (m.kind as i32) + r.n     // 7 + 1 + 2
    }
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 10
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
