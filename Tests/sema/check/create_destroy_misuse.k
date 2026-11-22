// A `@create` or `@destroy` of a shape that has no meaning is SC364E, not
// "not yet supported" (SC116E): `@create` takes one construction, a call of
// the type or an initializer, and `@destroy` one pointer. The attribute
// applies to the unary expression after it, member accesses included, so a
// member of the new object needs parentheses; that one has the fix-it.

class Config {
    pub var port: i32
    pub fn Config(self, port: i32) { self.port = port }
}

struct Point {
    pub var x: i32
}

fn misuse(a: *Config, b: *Config, k: i32) -> i32 {
    var p1 = @create Config(1).port
    var p2 = @create Point { x: 1 }->x
    var *n = @create 3
    var *m = @create k
    var *w = @create(8) Config(2)
    @destroy(a) b
    return 0
}

enum Shape {
    Circle { r: i32 },
    Dot,
}

fn headless() {
    var *v = @create .Dot
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: create_destroy_misuse.k:17:14: error [SC364E]: '@create' applies to the whole member access after it; a member of the object it creates is reached through parentheses: '(@create T(args))->member'
// DIAG-NEXT: fix-it:"{{.*}}create_destroy_misuse.k":{17:14-17:14}:"("
// DIAG-NEXT: fix-it:"{{.*}}create_destroy_misuse.k":{17:31-17:31}:")"
// DIAG-NEXT: fix-it:"{{.*}}create_destroy_misuse.k":{17:31-17:32}:"->"
// DIAG-NEXT: create_destroy_misuse.k:17:31: note [SC364N]: this member access is part of the operand
// DIAG: create_destroy_misuse.k:18:14: error [SC364E]: '@create' applies to the whole member access after it
// DIAG-NEXT: fix-it:"{{.*}}create_destroy_misuse.k":{18:14-18:14}:"("
// DIAG-NEXT: fix-it:"{{.*}}create_destroy_misuse.k":{18:36-18:36}:")"
// DIAG-NEXT: create_destroy_misuse.k:18:36: note [SC364N]: this member access is part of the operand
// DIAG: create_destroy_misuse.k:19:14: error [SC364E]: '@create' allocates and constructs one object: its operand is a construction, 'T(args)' or 'T { field: value }'
// DIAG-NEXT: create_destroy_misuse.k:19:22: note [SC364N]: this is the operand
// DIAG: create_destroy_misuse.k:20:14: error [SC364E]: '@create' allocates and constructs one object
// DIAG-NEXT: create_destroy_misuse.k:20:22: note [SC364N]: this is the operand
// DIAG: create_destroy_misuse.k:21:14: error [SC364E]: '@create' takes one attribute argument, the allocator by keyword ('@create(in: A) T(args)'): the type and its constructor arguments follow it, '@create T(args)' or '@create T { field: value }'
// DIAG: create_destroy_misuse.k:22:5: error [SC364E]: '@destroy' takes one pointer: '@destroy p' or '@destroy(p)'
// DIAG: create_destroy_misuse.k:32:14: error [SC364E]: '@create' needs the type it allocates: write '@create T { field: value }'
// DIAG-NEXT: create_destroy_misuse.k:32:22: note [SC364N]: this is the operand

// The fix-it's spelling compiles.
// RUN: sed -e 's/@create Config(1).port/(@create Config(1))->port/' -e 's/@create Point { x: 1 }->x/(@create Point { x: 1 })->x/' -e '/@create 3/d' -e '/@create k/d' -e '/@create(8)/d' -e '/@destroy(a) b/d' -e '/@create .Dot/d' %s > %t.k
// RUN: { %kairo %t.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FIXED --allow-empty
// FIXED-NOT: error
