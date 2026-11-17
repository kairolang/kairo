// A conversion operator is a member like any other: a `priv` one is refused
// outside its file however it is reached, by an implicit conversion (an
// argument, an initializer, a return), by a member found on the type it
// converts to, and by an explicit `as`. Its own file
// uses it freely (Inputs/access_implicit_conv_lib.k, which this file
// imports, has no diagnostics), an extension written here does not.

import self::Inputs::access_implicit_conv_lib::*

fn take(x: i64) -> i64 { return x }

fn give(m: Meters) -> i64 { return m }

extend Meters {
    fn here(const self) -> i64 { return take(self) }
}

fn main() -> i32 {
    var m = Meters(3)
    var a = take(m)
    var b: i64 = m
    var c = m as i64
    var i = Inch(2)
    var d = i as f64
    var y = Yard(1)
    var f = y.twice() + y.own_twice()
    var e = lib_uses(m, i, y) + m.widened() + m.doubled() + give(m) + m.here()
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:12:36: error [SC242E]: operator 'op as' of 'Meters' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_implicit_conv_lib.k":{11:15-11:19}:"pub"
// DIAG-NEXT: {{.*}}/access_implicit_conv_lib.k:11:26: note [SC242N]: 'op as' is declared private here: accessible only in the file that declares 'Meters'
// DIAG: {{.*}}:15:46: error [SC242E]: operator 'op as' of 'Meters' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_implicit_conv_lib.k":{11:15-11:19}:"pub"
// DIAG-NEXT: {{.*}}/access_implicit_conv_lib.k:11:26: note [SC242N]: 'op as' is declared private here: accessible only in the file that declares 'Meters'
// DIAG: {{.*}}:20:18: error [SC242E]: operator 'op as' of 'Meters' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_implicit_conv_lib.k":{11:15-11:19}:"pub"
// DIAG-NEXT: {{.*}}/access_implicit_conv_lib.k:11:26: note [SC242N]: 'op as' is declared private here: accessible only in the file that declares 'Meters'
// DIAG: {{.*}}:21:18: error [SC242E]: operator 'op as' of 'Meters' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_implicit_conv_lib.k":{11:15-11:19}:"pub"
// DIAG-NEXT: {{.*}}/access_implicit_conv_lib.k:11:26: note [SC242N]: 'op as' is declared private here: accessible only in the file that declares 'Meters'
// DIAG: {{.*}}:22:13: error [SC242E]: operator 'op as' of 'Meters' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_implicit_conv_lib.k":{11:15-11:19}:"pub"
// DIAG-NEXT: {{.*}}/access_implicit_conv_lib.k:11:26: note [SC242N]: 'op as' is declared private here: accessible only in the file that declares 'Meters'
// DIAG: {{.*}}:24:13: error [SC242E]: operator 'op as' of 'Inch' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_implicit_conv_lib.k":{24:5-24:9}:"pub"
// DIAG-NEXT: {{.*}}/access_implicit_conv_lib.k:24:16: note [SC242N]: 'op as' is declared private here: accessible only in the file that declares 'Inch'
// DIAG: {{.*}}:26:13: error [SC242E]: operator 'op as' of 'Yard' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_implicit_conv_lib.k":{41:15-41:19}:"pub"
// DIAG-NEXT: {{.*}}/access_implicit_conv_lib.k:41:26: note [SC242N]: 'op as' is declared private here: accessible only in the file that declares 'Yard'
// END-GENERATED-CHECKS(DIAG)
