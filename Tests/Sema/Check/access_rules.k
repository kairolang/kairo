// AccessCheck from another module (Inputs/access_rules_lib.k): `priv` is
// the declaring file's (and the class's own), `prot` adds every subclass in
// any file, `pub` is everyone's; a class's variables are `priv` unless
// marked. Each refusal names the member, labels the use, notes the
// declaration, and offers `pub` as the fix-it. A subclass's own access to
// the `prot` members, `pub` members, and a `pub` nested type stay clean.

import Inputs::access_rules_lib::*

class Heir derives Vault {
    fn Heir(self) { Vault::Vault(self, 1, 2) }
    fn probe(const self) -> i32 { return self.shared + self.guard() }
    fn through(self, v: *Vault) -> i32 { return v->shared }
    fn bad(const self) -> i32 { return self.secret }
}

class Grandchild derives Heir {
    fn deep(const self) -> i32 { return self.shared }
}

fn outside() -> i32 {
    var v = Vault()
    var p: *Vault = &v
    var r = v.open
    r += v.secret
    r += p->secret
    r += v.shared
    r += v.peek()
    r += v.guard()
    r += Vault::count
    var w = Vault(3)
    var k = Vault::Key{}
    var kk: Vault::Key = k
    var d = Vault::Door{}
    r += d.d
    var c = Cell<i32>(1)
    r += c.item
    var s = Sealed()
    r += s.open
    var g = Guarded()
    r += g.open
    return r
}

fn main() -> i32 { return outside() }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:14:44: error [SC001E]: field 'secret' of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{4:5-4:5}:"pub "
// DIAG-NEXT: {{.*}}/access_rules_lib.k:4:9: note [SC001N]: 'secret' is private by default (a variable of a class is 'priv' unless marked): accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:25:11: error [SC001E]: field 'secret' of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{4:5-4:5}:"pub "
// DIAG-NEXT: {{.*}}/access_rules_lib.k:4:9: note [SC001N]: 'secret' is private by default (a variable of a class is 'priv' unless marked): accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:26:11: error [SC001E]: field 'secret' of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{4:5-4:5}:"pub "
// DIAG-NEXT: {{.*}}/access_rules_lib.k:4:9: note [SC001N]: 'secret' is private by default (a variable of a class is 'priv' unless marked): accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:27:11: error [SC001E]: field 'shared' of 'Vault' is protected
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{5:5-5:9}:"pub"
// DIAG-NEXT: {{.*}}/access_rules_lib.k:5:14: note [SC001N]: 'shared' is declared protected here: accessible only in the file that declares 'Vault' and in classes that derive from it
// DIAG: {{.*}}:28:11: error [SC001E]: method 'peek' of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{8:5-8:9}:"pub"
// DIAG-NEXT: {{.*}}/access_rules_lib.k:8:13: note [SC001N]: 'peek' is declared private here: accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:29:11: error [SC001E]: method 'guard' of 'Vault' is protected
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{9:5-9:9}:"pub"
// DIAG-NEXT: {{.*}}/access_rules_lib.k:9:13: note [SC001N]: 'guard' is declared protected here: accessible only in the file that declares 'Vault' and in classes that derive from it
// DIAG: {{.*}}:30:15: error [SC001E]: static member 'count' of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{7:5-7:5}:"pub "
// DIAG-NEXT: {{.*}}/access_rules_lib.k:7:12: note [SC001N]: 'count' is private by default (a variable of a class is 'priv' unless marked): accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:31:13: error [SC001E]: this constructor of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{11:5-11:9}:"pub"
// DIAG-NEXT: {{.*}}/access_rules_lib.k:11:13: note [SC001N]: 'Vault' is declared private here: accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:32:18: error [SC001E]: type 'Key' of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{13:5-13:9}:"pub"
// DIAG-NEXT: {{.*}}/access_rules_lib.k:13:16: note [SC001N]: 'Key' is declared private here: accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:33:20: error [SC001E]: type 'Key' of 'Vault' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{13:5-13:9}:"pub"
// DIAG-NEXT: {{.*}}/access_rules_lib.k:13:16: note [SC001N]: 'Key' is declared private here: accessible only in the file that declares 'Vault'
// DIAG: {{.*}}:37:11: error [SC001E]: field 'item' of 'Cell' is private
// DIAG-NEXT: fix-it:"{{.*}}/access_rules_lib.k":{18:5-18:5}:"pub "
// DIAG-NEXT: {{.*}}/access_rules_lib.k:18:9: note [SC001N]: 'item' is private by default (a variable of a class is 'priv' unless marked): accessible only in the file that declares 'Cell'
// DIAG: {{.*}}:39:11: error [SC001E]: 'open' is inaccessible through 'Sealed': 'Sealed' derives 'Vault' as private
// DIAG-NEXT: {{.*}}/access_rules_lib.k:22:26: note [SC001N]: 'Sealed' declares its base 'Vault' 'priv' here, so the members of 'Vault' are private to 'Sealed' and its file
// DIAG: {{.*}}:41:11: error [SC001E]: 'open' is inaccessible through 'Guarded': 'Guarded' derives 'Vault' as protected
// DIAG-NEXT: {{.*}}/access_rules_lib.k:26:27: note [SC001N]: 'Guarded' declares its base 'Vault' 'prot' here, so the members of 'Vault' are protected to 'Guarded' and its file
// END-GENERATED-CHECKS(DIAG)
