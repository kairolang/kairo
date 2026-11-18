// `const` before a plain capture name: the recovery check after `const`
// accepts `*` or an identifier. Built by Stage 0 it read
// `!check(*) && !check_ident()` as `!(check(*) && !check_ident())`, so a
// name after `const` was "expected '*' or identifier after 'const'".

fn main() -> i32 {
    var x = 3
    var y = 4
    var f = fn () |const x, const *y| -> i32 { return x + *y }
    return f() - 7
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
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
