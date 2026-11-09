// The default visibility rule (decided 2026-11-08) for a file in no module:
// Inputs/visibility_nomod/lib.k has no module.k above it, so `priv`,
// `prot` and every unmarked declaration in it are its own. Reached through
// the module handle (`lib::priv_fn`, AccessCheck) and as members: each is
// SC242E with a note and a fix-it making it `pub`, and a `prot` one also
// carries SC272W, chained, naming the missing module.k. A class's `prot`
// keeps its subclasses' reach (Sema/Check/access_prot_object.k).
//
// Under the hidden -fdefault-visibility=pub (the old rule, which build.py
// passes for the compiler's own tree) the unmarked function and method are
// public again and only the written `priv` / `prot` and a class's unmarked
// variable are refused.
//
// Reached bare through `import lib::*` (Inputs/visibility_nomod/bare_use.k)
// the same refusals are N's R047E, again with SC272W for `prot`.

import self::Inputs::visibility_nomod::lib

fn main() -> i32 {
    var b = lib::Box()
    var s = lib::open_fn() + lib::priv_fn() + lib::prot_fn() + lib::bare_fn()
    var m = b.shown + b.hidden + b.bare_m() + b.priv_m() + b.prot_m()
    return s + m + lib::lib_reads()
}

// --- lit wiring -----------------------------------------------------------

// RUN: { %kairo %s --type-check-only -fdefault-visibility=pub 2>&1 || true; } | %FileCheck %s --check-prefix=OLD --implicit-check-not="error [" --implicit-check-not="warning ["
// OLD: {{.*}}:21:33: error [SC242E]: 'priv_fn' is private to its file
// OLD: {{.*}}:21:50: error [SC242E]: 'prot_fn' is protected, and its file is in no module, so it is visible only in its file
// OLD: {{.*}}:21:50: warning [SC272W]: 'prot_fn' is 'prot', but its file has no module.k above it
// OLD: {{.*}}:22:24: error [SC242E]: field 'hidden' of 'Box' is private
// OLD: lib.k:11:9: note [SC242N]: 'hidden' is private by default (a variable of a class is 'priv' unless marked): accessible only in the file that declares 'Box'
// OLD: {{.*}}:22:48: error [SC242E]: method 'priv_m' of 'Box' is private
// OLD: {{.*}}:22:61: error [SC242E]: method 'prot_m' of 'Box' is protected
// OLD: {{.*}}:22:61: warning [SC272W]: 'prot_m' is 'prot'

// RUN: cd %S/Inputs/visibility_nomod && { %kairo bare_use.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BARE --implicit-check-not="error [" --implicit-check-not="warning ["
// BARE: bare_use.k:6:24: error [R047E]: 'priv_fn' is imported but is declared private in its module
// BARE-NEXT: fix-it:"{{.*}}/lib.k":{4:1-4:5}:"pub"
// BARE-NEXT: lib.k:4:9: note [R047N]: 'priv_fn' is declared here
// BARE: bare_use.k:6:36: error [R047E]: 'prot_fn' is imported but is declared protected, and its file is in no module: visible only in its file
// BARE-NEXT: fix-it:"{{.*}}/lib.k":{5:1-5:5}:"pub"
// BARE-NEXT: lib.k:5:9: note [R047N]: 'prot_fn' is declared here
// BARE-NEXT: bare_use.k:6:36: warning [SC272W]: 'prot_fn' is 'prot', but its file has no module.k above it, so it is shared with no other file; add a module.k to the directory that should share it
// BARE: bare_use.k:6:48: error [R047E]: 'bare_fn' is imported but is private to its file: a declaration with no visibility keyword is 'priv' when its file has no module.k above it
// BARE-NEXT: fix-it:"{{.*}}/lib.k":{6:1-6:1}:"pub "
// BARE-NEXT: lib.k:6:4: note [R047N]: 'bare_fn' is declared here

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:21:33: error [SC242E]: 'priv_fn' is private to its file
// DIAG-NEXT: fix-it:"{{.*}}/lib.k":{4:1-4:5}:"pub"
// DIAG-NEXT: {{.*}}/lib.k:4:9: note [SC242N]: 'priv_fn' is declared private here
// DIAG: {{.*}}:21:50: error [SC242E]: 'prot_fn' is protected, and its file is in no module, so it is visible only in its file
// DIAG-NEXT: fix-it:"{{.*}}/lib.k":{5:1-5:5}:"pub"
// DIAG-NEXT: {{.*}}/lib.k:5:9: note [SC242N]: 'prot_fn' is declared protected here
// DIAG: {{.*}}:21:50: warning [SC272W]: 'prot_fn' is 'prot', but its file has no module.k above it, so it is shared with no other file; add a module.k to the directory that should share it
// DIAG: {{.*}}:21:67: error [SC242E]: 'bare_fn' is private to its file
// DIAG-NEXT: fix-it:"{{.*}}/lib.k":{6:1-6:1}:"pub "
// DIAG-NEXT: {{.*}}/lib.k:6:4: note [SC242N]: 'bare_fn' is private by default: a declaration with no visibility keyword is 'priv' when its file has no module.k above it
// DIAG: {{.*}}:22:24: error [SC242E]: field 'hidden' of 'Box' is private
// DIAG-NEXT: fix-it:"{{.*}}/lib.k":{11:5-11:5}:"pub "
// DIAG-NEXT: {{.*}}/lib.k:11:9: note [SC242N]: 'hidden' is private by default (a variable of a class is 'priv' unless marked): accessible only in the file that declares 'Box'
// DIAG: {{.*}}:22:35: error [SC242E]: method 'bare_m' of 'Box' is private
// DIAG-NEXT: fix-it:"{{.*}}/lib.k":{12:5-12:5}:"pub "
// DIAG-NEXT: {{.*}}/lib.k:12:8: note [SC242N]: 'bare_m' is private by default (a member with no visibility keyword is 'priv' when its file has no module.k above it): accessible only in the file that declares 'Box'
// DIAG: {{.*}}:22:48: error [SC242E]: method 'priv_m' of 'Box' is private
// DIAG-NEXT: fix-it:"{{.*}}/lib.k":{13:5-13:9}:"pub"
// DIAG-NEXT: {{.*}}/lib.k:13:13: note [SC242N]: 'priv_m' is declared private here: accessible only in the file that declares 'Box'
// DIAG: {{.*}}:22:61: error [SC242E]: method 'prot_m' of 'Box' is protected
// DIAG-NEXT: fix-it:"{{.*}}/lib.k":{14:5-14:9}:"pub"
// DIAG-NEXT: {{.*}}/lib.k:14:13: note [SC242N]: 'prot_m' is declared protected here: accessible only in the file that declares 'Box' and in classes that derive from it
// DIAG: {{.*}}:22:61: warning [SC272W]: 'prot_m' is 'prot', but its file has no module.k above it, so it is shared with no other file; add a module.k to the directory that should share it
// END-GENERATED-CHECKS(DIAG)
