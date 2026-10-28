// An overloaded operator is a member like any other: its `priv` / `prot`
// is checked where an operator expression selects it (AccessCheck), as a
// `.` call of it would be. From another module (Inputs/access_operators_lib.k)
// a binary, compound-assignment, subscript, comparison and unary `priv`
// operator is refused; a `prot` one is a subclass's, through its own kind
// of object only ([class.protected]: `self - 1`, not `o - 1` with `o: Num`); a `pub`
// one and the library's own uses are clean.

import Inputs::access_operators_lib::*

class Sub derives Num {
    fn Sub(self) { Num::Num(self, 1) }
    fn diff(const self) -> Num { return self - 1 }
    fn back(const self, o: Num) -> Num { return o - 1 }
}

fn outside() -> i32 {
    var a = Num(1)
    var b = Num(2)
    var c = a + b
    var d = a - 2
    var e = a * b
    var f = a[1]
    if a == b { return 1 }
    a %= 2
    var g = -a
    return e.v + lib_sum(a, b)
}

fn main() -> i32 { return outside() }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:14:51: error [SC001E]: protected operator 'op -' of 'Num' is reached here through a 'Num', not through 'Sub' or a class deriving from it
// DIAG-NEXT: fix-it:"{{.*}}/access_operators_lib.k":{7:5-7:9}:"pub"
// DIAG-NEXT: {{.*}}/access_operators_lib.k:7:16: note [SC001N]: 'op -' is protected: outside the file that declares 'Num', a class deriving from it reaches it only through an object of its own class (as C++ does, [class.protected])
// DIAG: {{.*}}:20:15: error [SC001E]: operator 'op +' of 'Num' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_operators_lib.k":{6:5-6:9}:"pub"
// DIAG-NEXT: {{.*}}/access_operators_lib.k:6:16: note [SC001N]: 'op +' is declared private here: accessible only in the file that declares 'Num'
// DIAG: {{.*}}:21:15: error [SC001E]: operator 'op -' of 'Num' is protected
// DIAG-NEXT: fix-it:"{{.*}}/access_operators_lib.k":{7:5-7:9}:"pub"
// DIAG-NEXT: {{.*}}/access_operators_lib.k:7:16: note [SC001N]: 'op -' is declared protected here: accessible only in the file that declares 'Num' and in classes that derive from it
// DIAG: {{.*}}:23:13: error [SC001E]: operator 'op []' of 'Num' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_operators_lib.k":{9:5-9:9}:"pub"
// DIAG-NEXT: {{.*}}/access_operators_lib.k:9:16: note [SC001N]: 'op []' is declared private here: accessible only in the file that declares 'Num'
// DIAG: {{.*}}:24:10: error [SC001E]: operator 'op ==' of 'Num' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_operators_lib.k":{10:5-10:9}:"pub"
// DIAG-NEXT: {{.*}}/access_operators_lib.k:10:16: note [SC001N]: 'op ==' is declared private here: accessible only in the file that declares 'Num'
// DIAG: {{.*}}:25:7: error [SC001E]: operator 'op %=' of 'Num' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_operators_lib.k":{11:5-11:9}:"pub"
// DIAG-NEXT: {{.*}}/access_operators_lib.k:11:16: note [SC001N]: 'op %=' is declared private here: accessible only in the file that declares 'Num'
// DIAG: {{.*}}:26:13: error [SC001E]: operator 'op -' of 'Num' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_operators_lib.k":{12:5-12:9}:"pub"
// DIAG-NEXT: {{.*}}/access_operators_lib.k:12:16: note [SC001N]: 'op -' is declared private here: accessible only in the file that declares 'Num'
// END-GENERATED-CHECKS(DIAG)
