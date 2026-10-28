import lib::*

class Bag impl Sized {
    pub var n: i32
    fn Bag(self, n: i32) { self.n = n }
    fn size(const self) -> i32 { return self.n }
}

// lib.k declares `total` and defines it after a caller; both calls from
// here resolve to the one function.
fn main() -> i32 {
    return total(Bag(2), Bag(3)) + twice(Bag(4))     // 5 + 8
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
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 13
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
