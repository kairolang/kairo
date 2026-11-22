// An allocation attribute takes no generic arguments. The parser rejects the
// spelling (S001E) and its fix-it moves a type argument to the operand
// (`@alloc Box`, `@try_create Box(1)`) or drops the arguments when the
// operand already holds the type. A parser error stops the compile, so this
// file holds nothing else.

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
}

fn bad(p: *Box, q: unsafe *u8) {
    var j? = @alloc<Box>
    var *k? = @try_create<Box>(1)
    @free<Box>(p)
    var *a = @create<Box>(1)
    @destroy<Box>(a)
    var m? = @alloc<Box>(count: 2)
    var unsafe *n = @alloc_zeroed<u8>(size: 8, align: 8)
    @free<Box>(size: 8, align: 8) q
    var unsafe *o = @resize<u8>(size: 8, new_size: 16, align: 8) q
    var r = @resize_in_place<u8>(size: 8, new_size: 16, align: 8) q
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: attr_generic_args_error.k:13:20: error [S001E]: '@alloc' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{13:20-13:25}:" Box"
// DIAG: attr_generic_args_error.k:14:26: error [S001E]: '@try_create' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{14:26-14:31}:" Box"
// DIAG: attr_generic_args_error.k:15:10: error [S001E]: '@free' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{15:10-15:15}:""
// DIAG: attr_generic_args_error.k:16:21: error [S001E]: '@create' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{16:21-16:26}:" Box"
// DIAG: attr_generic_args_error.k:17:13: error [S001E]: '@destroy' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{17:13-17:18}:""
// DIAG: attr_generic_args_error.k:18:20: error [S001E]: '@alloc' takes no generic arguments
// DIAG: attr_generic_args_error.k:19:34: error [S001E]: '@alloc_zeroed' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{19:34-19:38}:""
// DIAG: attr_generic_args_error.k:20:10: error [S001E]: '@free' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{20:10-20:15}:""
// DIAG: attr_generic_args_error.k:21:28: error [S001E]: '@resize' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{21:28-21:32}:""
// DIAG: attr_generic_args_error.k:22:24: error [S001E]: '@resize_in_place' takes no generic arguments
// DIAG-NEXT: fix-it:"{{.*}}attr_generic_args_error.k":{22:24-22:28}:""
