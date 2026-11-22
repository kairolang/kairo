// The allocation attributes take keyword arguments, and a use that does not
// match a form is SC365E, with a note naming the spellings the attribute has:
// a missing keyword, an unknown keyword (with a did-you-mean fix-it), a
// keyword twice (the note points at the first), a positional argument (the
// fix-it adds `in: ` when it is the allocator), keywords that no form
// combines, and `in:` with something that is not a type.

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
}

class Arena { }

fn bad(p: *Box, q: unsafe *u8) {
    var unsafe *a = @alloc(size: 64)
    var unsafe *b = @alloc(sz: 64, align: 8)
    var unsafe *c = @alloc(size: 64, size: 32, align: 8)
    var unsafe *d = @alloc(64, 8)
    var f? = @alloc(count: 2, size: 8, align: 8) Box
    @free(size: 8) q
    @free(Arena) p
    @resize(size: 8, align: 8) q
    var *h = @create(in: 5) Box(1)
    var unsafe *i = @alloc_zeroed(size: 8)
    var j = @try_resize(size: 8, new_size: 8) q
    var *k? = @try_create(in: Arena, in: Arena) Box(1)
    @destroy(in: Arena, extra: 1) p
    @free(size: 8, align: 8, count: 3) q
    var unsafe *l = @alloc(align: 8)
    var *m = @create(allocator: Arena) Box(1)
    var *o? = @try_create(Arena) Box(1)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: alloc_attr_args.k:16:21: error [SC365E]: '@alloc' with 'size:' also needs 'align:'
// DIAG-NEXT: alloc_attr_args.k:16:21: note [SC365N]: it is written '@alloc T', '@alloc(count: n) T' or '@alloc(size: n, align: a)'
// DIAG: alloc_attr_args.k:17:28: error [SC365E]: '@alloc' has no keyword argument 'sz:'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_args.k":{17:28-17:30}:"size"
// DIAG-NEXT: alloc_attr_args.k:17:21: note [SC365N]: it takes 'size:', 'align:', 'count:' and 'in:'
// DIAG: alloc_attr_args.k:18:38: error [SC365E]: '@alloc' is given 'size:' twice
// DIAG-NEXT: alloc_attr_args.k:18:28: note [SC365N]: first given here
// DIAG: alloc_attr_args.k:19:28: error [SC365E]: '@alloc' takes keyword arguments only: it is written '@alloc T', '@alloc(count: n) T' or '@alloc(size: n, align: a)'
// DIAG: alloc_attr_args.k:20:14: error [SC365E]: '@alloc' has no form that takes 'size:', 'align:' and 'count:' together
// DIAG-NEXT: alloc_attr_args.k:20:14: note [SC365N]: it is written '@alloc T', '@alloc(count: n) T' or '@alloc(size: n, align: a)'
// DIAG: alloc_attr_args.k:21:5: error [SC365E]: '@free' with 'size:' also needs 'align:'
// DIAG-NEXT: alloc_attr_args.k:21:5: note [SC365N]: it is written '@free p' or '@free(size: n, align: a) p'
// DIAG: alloc_attr_args.k:22:11: error [SC365E]: '@free' takes keyword arguments only: it is written '@free p' or '@free(size: n, align: a) p'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_args.k":{22:11-22:11}:"in: "
// DIAG: alloc_attr_args.k:23:5: error [SC365E]: '@resize' with 'size:' and 'align:' also needs 'new_size:'
// DIAG-NEXT: alloc_attr_args.k:23:5: note [SC365N]: it is written '@resize(size: old, new_size: n, align: a) p'
// DIAG: alloc_attr_args.k:24:26: error [SC365E]: 'in:' names the allocator, a type: '@create' with 'in: A' allocates from, or frees to, A instead of the allocator in effect
// DIAG: alloc_attr_args.k:25:21: error [SC365E]: '@alloc_zeroed' with 'size:' also needs 'align:'
// DIAG-NEXT: alloc_attr_args.k:25:21: note [SC365N]: it is written '@alloc_zeroed(size: n, align: a)'
// DIAG: alloc_attr_args.k:26:13: error [SC365E]: '@try_resize' with 'size:' and 'new_size:' also needs 'align:'
// DIAG-NEXT: alloc_attr_args.k:26:13: note [SC365N]: it is written '@try_resize(size: old, new_size: n, align: a) p'
// DIAG: alloc_attr_args.k:27:38: error [SC365E]: '@try_create' is given 'in:' twice
// DIAG-NEXT: alloc_attr_args.k:27:27: note [SC365N]: first given here
// DIAG: alloc_attr_args.k:28:25: error [SC365E]: '@destroy' has no keyword argument 'extra:'
// DIAG-NEXT: alloc_attr_args.k:28:5: note [SC365N]: it takes 'in:'
// DIAG: alloc_attr_args.k:29:30: error [SC365E]: '@free' has no keyword argument 'count:'
// DIAG-NEXT: alloc_attr_args.k:29:5: note [SC365N]: it takes 'size:', 'align:' and 'in:'
// DIAG: alloc_attr_args.k:30:21: error [SC365E]: '@alloc' with 'align:' also needs 'size:'
// DIAG-NEXT: alloc_attr_args.k:30:21: note [SC365N]: it is written '@alloc T', '@alloc(count: n) T' or '@alloc(size: n, align: a)'
// DIAG: alloc_attr_args.k:31:22: error [SC365E]: '@create' has no keyword argument 'allocator:'
// DIAG-NEXT: alloc_attr_args.k:31:14: note [SC365N]: it takes 'in:'
// DIAG: alloc_attr_args.k:32:27: error [SC365E]: '@try_create' takes keyword arguments only: it is written '@try_create T(args)' or '@try_create T { field: value }'
// DIAG-NEXT: fix-it:"{{.*}}alloc_attr_args.k":{32:27-32:27}:"in: "
