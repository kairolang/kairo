// Two `op as` requirements in one interface, to `i32` and to `i64`, used
// through a bound. Each requirement's witness member is a static function
// of the same parameters, so its C++ name carries the target
// (`__kairo_op_as_<type>`): one name for both was a redeclaration C++
// cannot overload on its return type alone.

interface Measure {
    fn op as(const self) -> i32
    fn op as(const self) -> i64
}

class Rod impl Measure {
    var n: i32
    fn Rod(self, n: i32) { self.n = n }
    fn op as(const self) -> i32 { return self.n }
    fn op as(const self) -> i64 { return self.n * 10 }
}

fn <T impl Measure> both(x: T) -> i32 {
    var a = x as i32
    var b = x as i64
    return a + (b as i32)
}

fn main() -> i32 {
    return both(Rod(3))                 // 3 + 30
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
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 33
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
