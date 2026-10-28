// G21 (Compiler/Sema/NULLABLE.md 1.8): the shorthand lint. A `var` /
// `const` / `static` binding with NO annotation and NO shorthand whose
// inferred type is nullable or a pointer is SC001W, with the fix-it that
// writes the shorthand (Sema/Check/ShorthandLint.k):
//   - `T?`: "'x' is nullable; write 'x?' so it reads as one", `?` after
//     the name;
//   - a pointer of depth n: "'x' is a pointer; write '*x'", n stars before
//     the name, `unsafe *` when the outermost pointer is unsafe;
//   - a nullable pointer: one warning, both fix-its.
// Not warned: an annotated binding, one that already uses a shorthand (even
// partly: `var c? = &x` is `(*i32)?`), a plain value, destructuring / `for`
// binders, a dependent type in a generic body, a `|*x|` capture, an
// errored binding. A local declared in a closure IS warned: inside
// `|*x|`, `x` is the pointer, so `var q = x` is one.

fn find() -> i32? { return 3 }
fn raw(p: *i32) -> unsafe *i32 { unsafe { return p as unsafe *i32 } }
fn rawpp(p: *i32) -> unsafe **i32 { return &null }
fn maybe(p: *i32) -> (*i32)? { return p }

var gx = 1
var gn = find()
static sp = &gx

fn fires() {
    var x = 5
    var n = find()
    const c = find()
    var p = &x
    var pp = &p
    var ppp = &pp
    var u = raw(&x)
    var uu = rawpp(&x)
    var m = maybe(&x)
    for var i = &x; *i < 5; *i += 1 { }
    var f = fn ()|*x| { var q = x; }
}

fn quiet() {
    var x = 5
    var a = 5
    var s = "s"
    var p: *i32 = &x
    var n: i32? = find()
    var *p2 = &x
    var n2? = find()
    var c? = &x
    var unsafe *u = raw(&x)
    var *m? = maybe(&x)
    var (t1, t2) = (find(), &x)
    for var e in [1, 2] { }
    var cl = fn ()|*x| { *x = 1; }
    var bad = maybe(5)
    var bad2 = &x + "s"
}

fn <T> gen(t: T, p: *T) {
    var a = t
    var b = p
    var c = &t
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:22:5: warning [SC001W]: 'gn' is nullable; write 'gn?' so it reads as one
// CHECK-NEXT: fix-it:{{.*}}:{22:7-22:7}:"?"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:23:8: warning [SC001W]: 'sp' is a pointer; write '*sp'
// CHECK-NEXT: fix-it:{{.*}}:{23:8-23:8}:"*"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:27:9: warning [SC001W]: 'n' is nullable; write 'n?' so it reads as one
// CHECK-NEXT: fix-it:{{.*}}:{27:10-27:10}:"?"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:28:11: warning [SC001W]: 'c' is nullable; write 'c?' so it reads as one
// CHECK-NEXT: fix-it:{{.*}}:{28:12-28:12}:"?"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:29:9: warning [SC001W]: 'p' is a pointer; write '*p'
// CHECK-NEXT: fix-it:{{.*}}:{29:9-29:9}:"*"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:30:9: warning [SC001W]: 'pp' is a pointer; write '**pp'
// CHECK-NEXT: fix-it:{{.*}}:{30:9-30:9}:"**"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:31:9: warning [SC001W]: 'ppp' is a pointer; write '***ppp'
// CHECK-NEXT: fix-it:{{.*}}:{31:9-31:9}:"***"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:32:9: warning [SC001W]: 'u' is a pointer; write 'unsafe *u'
// CHECK-NEXT: fix-it:{{.*}}:{32:9-32:9}:"unsafe *"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:33:9: warning [SC001W]: 'uu' is a pointer; write 'unsafe **uu'
// CHECK-NEXT: fix-it:{{.*}}:{33:9-33:9}:"unsafe **"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:34:9: warning [SC001W]: 'm' is a nullable pointer; write '*m?' so it reads as one
// CHECK-NEXT: fix-it:{{.*}}:{34:9-34:9}:"*"
// CHECK-NEXT: fix-it:{{.*}}:{34:10-34:10}:"?"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:35:13: warning [SC001W]: 'i' is a pointer; write '*i'
// CHECK-NEXT: fix-it:{{.*}}:{35:13-35:13}:"*"
// CHECK-NOT: {{warning|error}}
// CHECK: shorthand_lint.k:36:29: warning [SC001W]: 'q' is a pointer; write '*q'
// CHECK-NEXT: fix-it:{{.*}}:{36:29-36:29}:"*"
// CHECK-NOT: warning
// The errored bindings in quiet() report their own errors and no lint.
// CHECK: shorthand_lint.k:53:15: error [SC063E]
// CHECK-NOT: warning
// CHECK: shorthand_lint.k:54:16: error [SC066E]
// CHECK-NOT: {{warning|error}}
