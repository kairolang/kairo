// SC275W: `for x in v` binds a copy of each element (library/core/
// containers.mdx, `Vector.op in`), so a write to `x` that nothing in the
// body reads afterwards is lost: it was meant for the element. The fix-it
// inserts `*` before the binder (`for *x in v`). Warned: a field write, a
// whole-variable assignment, a compound assignment, `&x` passed to an
// `@inout` parameter, an element of a C++ range. Not warned: a read after
// the write, `for *x`, an integer range, a pointer element, `x` taken by
// `&` that is not an `@inout` marker, a read in a nested loop that writes.

ffi "c++" import "for_copy_lint.h"

struct P { pub var x: i32; pub var y: i32 }

fn bump(@inout n: i32) { n += 1 }
fn keep(p: *i32) { }

fn fires(ps: [P], xs: [i32], row: fcl::Row) {
    for p in ps { p.x = 0 }
    for p in ps { p = P{x: 1, y: 2} }
    for v in xs { v += 1 }
    for v in xs { bump(&v) }
    for p in ps { p.x = p.y + 1 }
    for c in row { c.v = 3 }
}

fn quiet(ps: [P], xs: [i32], qs: [*P]) -> i32 {
    var t = 0
    for p in ps { p.x = 1; t += p.x }
    for *p in ps { p->x = 0 }
    for i in 0..3 { i = 2 }
    for q in qs { q->x = 0 }
    for v in xs { keep(&v); v = 1 }
    for p in ps { while t < 3 { t += p.x; p.x = 1 } }
    return t
}

// RUN: { %kairo %s --type-check-only -A SC224W 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{warning|error}} [
// CHECK: for_copy_lint.k:18:19: warning [SC275W]: this writes to a copy of the element; the collection is not changed
// CHECK-NEXT: fix-it:{{.*}}:{18:9-18:9}:"*"
// CHECK-NEXT: for_copy_lint.k:18:9: note [SC275N]: 'p' is bound by value here; 'for *p' binds a pointer to the element, and uses of 'p' then go through it
// CHECK-NOT: {{warning|error}} [
// CHECK: for_copy_lint.k:19:19: warning [SC275W]
// CHECK-NEXT: fix-it:{{.*}}:{19:9-19:9}:"*"
// CHECK-NOT: {{warning|error}} [
// CHECK: for_copy_lint.k:20:19: warning [SC275W]
// CHECK-NOT: {{warning|error}} [
// CHECK: for_copy_lint.k:21:25: warning [SC275W]
// CHECK-NOT: {{warning|error}} [
// CHECK: for_copy_lint.k:22:19: warning [SC275W]
// CHECK-NOT: {{warning|error}} [
// CHECK: for_copy_lint.k:23:20: warning [SC275W]
// CHECK-NEXT: fix-it:{{.*}}:{23:9-23:9}:"*"
// CHECK-NOT: {{warning|error}} [

// -A silences it like any warning.
// RUN: { %kairo %s --type-check-only -A SC275W 2>&1 || true; } | %FileCheck %s --check-prefix=QUIET --allow-empty
// QUIET-NOT: SC275W
