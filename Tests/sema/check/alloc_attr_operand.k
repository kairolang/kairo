// An allocation attribute whose operand has the wrong shape is SC364E:
// `@alloc` takes a type (a construction belongs to `@create`, with that
// fix-it), `@try_create` a construction, `@destroy` and `@free` a pointer.
// `@create(A) T()` and `@destroy(a) b` keep their messages, and a type
// written where the allocator goes gets the `in: ` fix-it. `@free(p)` and
// `@destroy(p)` are the parenthesised spelling of the operand and are accepted.

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
}

class Arena {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
}

fn bad(p: *Box, k: i32) panic(AllocError) {
    var e? = @alloc Box(1)
    var f? = @try_create 3
    var g? = @try_create k
    @destroy(in: Arena)
    @destroy(Arena) p
    var h? = @try_create(Arena) Box(1)
    var *i = @create(Arena) Box(1)
    @free(in: Arena)
    var j? = @try_create Box(1).v
    var u? = @alloc 5
    var w? = @alloc(count: 3) Box(1)
}

fn good(p: *Box, q: *Box, r: *Box, s: *Box) {
    @free(p)
    @destroy(q)
    @free r
    @destroy s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: alloc_attr_operand.k:19:14: error [SC364E]: '@alloc' allocates storage for a type and constructs nothing: its operand is the type, '@alloc T' or '@alloc(count: n) T'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_operand.k":{19:15-19:20}:"create"
// DIAG-NEXT: alloc_attr_operand.k:19:21: note [SC364N]: this is the operand
// DIAG: alloc_attr_operand.k:20:14: error [SC364E]: '@try_create' allocates and constructs one object: its operand is a construction, 'T(args)' or 'T { field: value }'
// DIAG-NEXT: alloc_attr_operand.k:20:26: note [SC364N]: this is the operand
// DIAG: alloc_attr_operand.k:21:14: error [SC364E]: '@try_create' allocates and constructs one object: its operand is a construction, 'T(args)' or 'T { field: value }'
// DIAG-NEXT: alloc_attr_operand.k:21:26: note [SC364N]: this is the operand
// DIAG: alloc_attr_operand.k:22:5: error [SC364E]: '@destroy' is written '@destroy p'
// DIAG: alloc_attr_operand.k:23:5: error [SC364E]: '@destroy' takes one pointer: '@destroy p' or '@destroy(p)'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_operand.k":{23:14-23:14}:"in: "
// DIAG-NEXT: alloc_attr_operand.k:23:14: note [SC364N]: the one argument it takes is the allocator, by keyword: '@destroy' with 'in: A'
// DIAG: alloc_attr_operand.k:24:26: error [SC365E]: '@try_create' takes keyword arguments only: it is written '@try_create T(args)' or '@try_create T { field: value }'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_operand.k":{24:26-24:26}:"in: "
// DIAG: alloc_attr_operand.k:25:14: error [SC364E]: '@create' takes one attribute argument, the allocator by keyword ('@create(in: A) T(args)'): the type and its constructor arguments follow it, '@create T(args)' or '@create T { field: value }'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_operand.k":{25:22-25:22}:"in: "
// DIAG-NEXT: alloc_attr_operand.k:25:22: note [SC364N]: the one argument it takes is the allocator, by keyword: '@create' with 'in: A'
// DIAG: alloc_attr_operand.k:26:5: error [SC364E]: '@free' is written '@free p' or '@free(size: n, align: a) p'
// DIAG: alloc_attr_operand.k:27:14: error [SC364E]: '@try_create' applies to the whole member access after it; a member of the object it creates is reached through parentheses: '(@try_create T(args))->member'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_operand.k":{27:14-27:14}:"("
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_operand.k":{27:32-27:32}:")"
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_operand.k":{27:32-27:33}:"->"
// DIAG-NEXT: alloc_attr_operand.k:27:32: note [SC364N]: this member access is part of the operand
// DIAG: alloc_attr_operand.k:28:14: error [SC364E]: '@alloc' allocates storage for a type and constructs nothing: its operand is the type, '@alloc T' or '@alloc(count: n) T'
// DIAG-NEXT: alloc_attr_operand.k:28:21: note [SC364N]: this is the operand
// DIAG: alloc_attr_operand.k:29:14: error [SC364E]: '@alloc' allocates storage for a type and constructs nothing: its operand is the type, '@alloc T' or '@alloc(count: n) T'
// DIAG-NEXT: alloc_attr_operand.k:29:31: note [SC364N]: this is the operand

// The fix-its' spelling compiles; the uses that have no fix-it are removed.
// RUN: sed -e 's/@alloc Box(1)/@create Box(1)/' -e 's/@create(Arena)/@create(in: Arena)/' -e 's/@destroy(Arena)/@destroy(in: Arena)/' -e 's/@try_create(Arena)/@try_create(in: Arena)/' -e '/@try_create 3/d' -e '/@try_create k/d' -e '/@destroy(in: Arena)$/d' -e '/@free(in: Arena)$/d' -e '/Box(1).v/d' -e '/@alloc 5/d' -e '/@alloc(count: 3)/d' %s > %t.k
// RUN: { %kairo %t.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FIXED --allow-empty
// FIXED-NOT: error
