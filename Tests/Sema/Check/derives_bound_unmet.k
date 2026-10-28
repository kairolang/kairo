// A `derives` bound (`<X derives B>`) is checked at the instance's use like
// an `impl` bound: the argument is B or reaches it through its bases. It was
// never checked at all, and it now carries weight: it is what makes `&self
// as *X` in a CRTP base a static_cast (crtp_cast_bound.k).
//
// Accepted: the base itself, a class two levels down, a generic instance
// reaching its base through its arguments. Rejected: an unrelated class, on
// a record and on a function, and the wrong instance of a generic base.

class B { }
class C derives B { }
class D derives C { }
class Plain { }

class <T> Src { }
class <T> Gen derives Src<T> { }

class <X derives B> Holder {
    pub var n: i32 = 0
}
fn <T derives B> take(t: *T) -> i32 { return 1 }
fn <T derives Src<i32>> src(t: *T) -> i32 { return 2 }

class Ok1 derives Holder<B> { }
class Ok2 derives Holder<D> { }
class Bad1 derives Holder<Plain> { }

fn main() -> i32 {
    var d = D()
    var p = Plain()
    var g = Gen<i32>()
    var h = Gen<f64>()
    return take(&d) + take(&p) + src(&g) + src(&h)
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:26:20: error [SC001E]: 'Plain' does not derive 'B'
// DIAG-NEXT: {{.*}}:18:8: note [I900N]: required by this bound
// DIAG: {{.*}}:33:23: error [SC001E]: 'Plain' does not derive 'B'
// DIAG-NEXT: {{.*}}:21:5: note [I900N]: required by this bound
// DIAG: {{.*}}:33:44: error [SC001E]: 'Gen<f64>' does not derive 'Src<i32>'
// DIAG-NEXT: {{.*}}:22:5: note [I900N]: required by this bound
// END-GENERATED-CHECKS(DIAG)
