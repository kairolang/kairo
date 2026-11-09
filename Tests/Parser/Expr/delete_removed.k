// Kairo has no `delete` expression (0.2.0): `delete p` is S091E with a
// fix-it to `@destroy`, `delete [] p` points at C++'s `@cxx::delete []`,
// and `x.op delete()` (the destructor's old name) is S090E with a fix-it
// to `finally`. `delete` stays a keyword, for these errors, `= delete` and
// `@cxx::delete`.

class R {
    var n: i32 = 0
    fn op finally(self) { self.n = 0 }
}

fn main() -> i32 {
    var *p = @create R()
    delete p
    var unsafe *a = @cxx::new [i32; 4]
    delete [] a
    var r = R()
    r.op delete()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: delete_removed.k:14:5: error [S091E]: Kairo has no 'delete' expression; '@destroy p' runs the destructor and frees the memory through the allocator that '@create' took it from
// CHECK-NEXT: fix-it:"{{.*}}delete_removed.k":{14:5-14:11}:"@destroy"
// CHECK: delete_removed.k:16:5: error [S091E]: Kairo has no 'delete' expression; memory from C++'s 'new T[n]' is freed with '@cxx::delete [] p'
// CHECK-NEXT: fix-it:"{{.*}}delete_removed.k":{16:5-16:11}:"@cxx::delete"
// CHECK: delete_removed.k:18:10: error [S090E]: the destructor is 'op finally'; 'op delete' is not a Kairo operator
// CHECK-NEXT: fix-it:"{{.*}}delete_removed.k":{18:10-18:16}:"finally"
