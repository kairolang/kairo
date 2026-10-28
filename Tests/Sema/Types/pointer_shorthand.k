// G20 (Compiler/Sema/NULLABLE.md 1.7): `var *y = e` declares `y` with
// `e`'s type and states that it is a pointer. A readability marker, never a
// conversion: `y` is `typeof(e)` whatever is written. The stars must be
// `e`'s pointer depth, `unsafe` must match the OUTERMOST pointer's safety
// (`unsafe **T` is an unsafe pointer to a safe `*T`), and a nullable `e`
// needs the `?` (`var *y? = e`; `e: *T` is wrapped once, as 1.6 does). A
// wrong marker is SC001E with a fix-it writing the right one; it does not
// poison `y`, so later uses type normally and nothing cascades.
//
// Dependent types are decided on the type as written (as 1.6 does): with
// `pp: **T`, `var *c = pp` is an error. A pointer prefix that ends in a bare
// parameter is only partly decidable: `var **a2 = p` with `p: *T` is right
// for `T = *U`, so at least the visible stars are required and the rest is
// accepted unchecked (generic bodies are typed once); `var *b2 = t` with
// `t: T` is accepted the same way.
//
// The shorthand goes through the same typing as `var y = e`, so the alias
// analysis still records the carrier: `var *p = &x; *p = null` weakens `x`
// (G17). The loop pre-scan treats `var *p? = &a` as it treats `var p? = &a`.

fn raw(p: *i32) -> unsafe *i32 { unsafe { return p as unsafe *i32 } }
fn rawpp(p: *i32) -> unsafe **i32 { return &null }
fn maybe(p: *i32) -> (*i32)? { return p }

fn <T> gen(t: T, p: *T, pp: **T) {
    var *a = p
    var **a2 = p
    var *b2 = t
    var *c = pp
    var **c2 = pp
}

fn read_early() -> i32 { return *early }
var gx = 3
var *early = &gx
static **gpp = &early

fn main() -> i32 {
    var x = 5
    var *p = &x
    var **pp = &p
    var ***ppp = &pp
    const *cp = &x
    var unsafe *u = raw(&x)
    var unsafe **w = rawpp(&x)
    var *n? = &x
    var *m? = maybe(&x)
    var after = *p + **pp + ***ppp
    return after
}

fn errors() {
    var x = 5
    var *p = &x
    var *bad = &p
    var ***bad2 = &p
    var *notp = x
    var *u2 = raw(&x)
    var unsafe *s = &x
    var **w2 = rawpp(&x)
    var *m2 = maybe(&x)
    var ok = **bad + 1
}

fn weakened() -> i32 {
    var x: i32? = 1
    var *p = &x
    *p = null
    return x + 0
}

fn loop_plain(n: i32) -> i32 {
    var a = 1
    var q: (*i32)? = &a
    var i = 0
    if q? {
        while i < n {
            var p? = &a
            i += *q
            q = p
        }
    }
    return i
}

fn loop_shorthand(n: i32) -> i32 {
    var a = 1
    var q: (*i32)? = &a
    var i = 0
    if q? {
        while i < n {
            var *p? = &a
            i += *q
            q = p
        }
    }
    return i
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: a : *T
// SEMA-DAG: a2 : *T
// SEMA-DAG: b2 : T
// SEMA-DAG: c : **T
// SEMA-DAG: c2 : **T
// SEMA-DAG: early : *i32
// SEMA-DAG: gpp : **i32
// SEMA-DAG: p : *i32
// SEMA-DAG: pp : **i32
// SEMA-DAG: ppp : ***i32
// SEMA-DAG: cp : *i32
// SEMA-DAG: u : unsafe *i32
// SEMA-DAG: w : unsafe **i32
// SEMA-DAG: n : *i32?
// SEMA-DAG: m : *i32?
// SEMA-DAG: after : i32
// The wrong markers keep the initializer's type.
// SEMA-DAG: bad : **i32
// SEMA-DAG: bad2 : **i32
// SEMA-DAG: notp : i32
// SEMA-DAG: u2 : unsafe *i32
// SEMA-DAG: s : *i32
// SEMA-DAG: w2 : unsafe **i32
// SEMA-DAG: m2 : *i32?
// SEMA-DAG: ok : i32

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:29:9: error [SC001E]: '*c' states a pointer of depth 1, but its initializer is '**T', a pointer of depth 2; write '**c'
// DIAG-NEXT: fix-it:{{.*}}:{29:9-29:10}:"**"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:55:9: error [SC001E]: '*bad' states a pointer of depth 1, but its initializer is '**i32', a pointer of depth 2; write '**bad'
// DIAG-NEXT: fix-it:{{.*}}:{55:9-55:10}:"**"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:56:9: error [SC001E]: '***bad2' states a pointer of depth 3, but its initializer is '**i32', a pointer of depth 2; write '**bad2'
// DIAG-NEXT: fix-it:{{.*}}:{56:9-56:12}:"**"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:57:9: error [SC001E]: '*notp' declares a pointer, but its initializer has type 'i32', which is not one
// DIAG-NEXT: fix-it:{{.*}}:{57:9-57:10}:""
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:58:9: error [SC001E]: '*u2' declares a safe pointer, but its initializer is the unsafe pointer 'unsafe *i32'; write 'unsafe *u2'
// DIAG-NEXT: fix-it:{{.*}}:{58:9-58:10}:"unsafe *"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:59:9: error [SC001E]: 'unsafe *s' declares an unsafe pointer, but its initializer is the safe pointer '*i32'; write '*s'
// DIAG-NEXT: fix-it:{{.*}}:{59:9-59:17}:"*"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:60:9: error [SC001E]: '**w2' declares a safe pointer, but its initializer is the unsafe pointer 'unsafe **i32'; write 'unsafe **w2'
// DIAG-NEXT: fix-it:{{.*}}:{60:9-60:11}:"unsafe **"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:61:10: error [SC001E]: '*m2' is initialized with a nullable '*i32?'; write '*m2?' so the declaration says it may be null
// DIAG-NEXT: fix-it:{{.*}}:{61:12-61:12}:"?"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:69:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: pointer_shorthand.k:68:5: note [I900N]: 'x' may be changed here, through a pointer to it
// DIAG-NOT: {{error|warning}}
// Both loops read the same: a loop-local is not classified by the pre-scan
// (ticketed), with or without the stars.
// DIAG: pointer_shorthand.k:79:19: error [SC001E]: 'q' may be null here
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand.k:93:19: error [SC001E]: 'q' may be null here
// DIAG-NOT: {{error|warning}}
