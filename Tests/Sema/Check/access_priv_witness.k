// A `priv` or `prot` member implements an interface requirement only for
// an `impl` declared in its own file (on the class, or on an `extend`
// there). The witness that forwards to it (`Area_witness<X>::area`) is C++
// outside the class, which the class befriends only for what its file
// declares it implements; for a structural conformance the access would be
// refused by clang -- inside the concept, silently, as "no matching
// function". Sq (declared on the class) and Tri (declared by an extension)
// conform; Rect, structural only, does not, and the error names its
// member and offers `pub`.

import Inputs::access_priv_witness_lib::*

fn <T impl Area> measure(t: T) -> i32 { return t.area() }

fn main() -> i32 {
    var a = measure(Sq())
    var b = measure(Tri())
    var c = measure(Rect())
    return a + b + c
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:18:13: error [SC001E]: 'Rect' does not conform to 'Area': its 'area' is not public, and its file declares no 'impl Area'
// DIAG-NEXT: fix-it:"{{.*}}/access_priv_witness_lib.k":{21:5-21:9}:"pub"
// DIAG-NEXT: {{.*}}:13:5: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}/access_priv_witness_lib.k:3:22: note [I900N]: 'area' is required here
// DIAG-NEXT: {{.*}}/access_priv_witness_lib.k:21:13: note [I900N]: 'area' is declared here: a private or protected member implements a requirement only for an 'impl' declared in its own file
// END-GENERATED-CHECKS(DIAG)
