// The implicit default constructor exists only when every base and field
// can be built from nothing. When one cannot, `var x: R` (and `R()`, and a
// field of type R a constructor leaves unbuilt) is an error naming the
// field or base that stops it: a field with no initializer whose type has
// no default (bool, a record with none, recursively), a `const` field with
// no initializer, a base with no default. Any declared constructor -- a
// transfer one included -- means there is no implicit one at all, as in
// C++. A dependent field answers per instance, so a generic record is only
// refused where its own non-dependent fields refuse it.

struct HasBool { var ok: bool }
struct HasConst { const k: i32 }
class Arg { pub var a: i32
    fn Arg(self, a: i32) { self.a = a } }
struct HoldsArg { var a: Arg }
struct Deep { var h: HasBool }          // through another implicit one
class NoDefBase { pub var a: Arg }
class Kid derives NoDefBase { }
class CopyOnly {
    pub var n: i32
    @copy fn CopyOnly(self, const other: Self) = default
}
class <T> GenBool { pub var t: T  pub var flag: bool }
struct Fine { var n: i32  var ok: bool = true  const k: i32 = 3 }

class Ctor {
    pub var d: Deep
    fn Ctor(self) { }
}

fn main() -> i32 {
    var a: HasBool
    var b: HasConst
    var c: HoldsArg
    var d: Deep
    var e: Kid
    var f: CopyOnly
    var g: GenBool<i32>
    var h = HasBool()
    var i: [HasBool; 2]
    var ok: Fine                        // ok
    return 0
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:28:8: error [SC001E]: constructor of 'Ctor' does not initialize field 'd', and 'Deep' has no default constructor: the implicit one cannot build field 'h', which has no initializer ('HasBool' has no default constructor: the implicit one cannot build field 'ok', which has no initializer ('bool' has no zero state: a default would have to guess true or false))
// DIAG-NEXT: {{.*}}:27:9: note [I900N]: 'd' is declared here without an initializer; assign it whole in every constructor ('self.d = ...'), or give it one
// DIAG: {{.*}}:32:5: error [SC001E]: 'a' is declared without an initializer, and 'HasBool' has no default constructor: the implicit one cannot build field 'ok', which has no initializer ('bool' has no zero state: a default would have to guess true or false); Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{32:19-32:19}:" = ..."
// DIAG: {{.*}}:33:5: error [SC001E]: 'b' is declared without an initializer, and 'HasConst' has no default constructor: the implicit one cannot give const field 'k' a value, and it has no initializer; Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{33:20-33:20}:" = ..."
// DIAG: {{.*}}:34:5: error [SC001E]: 'c' is declared without an initializer, and 'HoldsArg' has no default constructor: the implicit one cannot build field 'a', which has no initializer ('Arg' has no default constructor (declare 'fn Arg(self)')); Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{34:20-34:20}:" = ..."
// DIAG: {{.*}}:35:5: error [SC001E]: 'd' is declared without an initializer, and 'Deep' has no default constructor: the implicit one cannot build field 'h', which has no initializer ('HasBool' has no default constructor: the implicit one cannot build field 'ok', which has no initializer ('bool' has no zero state: a default would have to guess true or false)); Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{35:16-35:16}:" = ..."
// DIAG: {{.*}}:36:5: error [SC001E]: 'e' is declared without an initializer, and 'Kid' has no default constructor: the implicit one cannot build its base ('NoDefBase' has no default constructor: the implicit one cannot build field 'a', which has no initializer ('Arg' has no default constructor (declare 'fn Arg(self)'))); Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{36:15-36:15}:" = ..."
// DIAG: {{.*}}:37:5: error [SC001E]: 'f' is declared without an initializer, and 'CopyOnly' has no default constructor (declare 'fn CopyOnly(self)'); Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{37:20-37:20}:" = ..."
// DIAG: {{.*}}:38:5: error [SC001E]: 'g' is declared without an initializer, and 'GenBool' has no default constructor: the implicit one cannot build field 'flag', which has no initializer ('bool' has no zero state: a default would have to guess true or false); Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{38:24-38:24}:" = ..."
// DIAG: {{.*}}:39:13: error [SC001E]: 'HasBool()' cannot be called: 'HasBool' has no default constructor: the implicit one cannot build field 'ok', which has no initializer ('bool' has no zero state: a default would have to guess true or false)
// DIAG-NEXT: {{.*}}:11:1: note [SC001N]: 'HasBool' declared here
// DIAG: {{.*}}:40:5: error [SC001E]: 'i' is declared without an initializer, and 'HasBool' has no default constructor: the implicit one cannot build field 'ok', which has no initializer ('bool' has no zero state: a default would have to guess true or false); Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{40:24-40:24}:" = ..."
// END-GENERATED-CHECKS(DIAG)
