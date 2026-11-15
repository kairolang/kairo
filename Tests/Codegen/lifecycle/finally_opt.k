// At -O2 a local whose cleanup `finally()` elides compiles to its
// destructor's body where `finally()` is written: no `live` flag, no
// branch on one, no hook (Compiler/Spec/Lowering.md#union-storage-locals).
// The destructor and the use both write `hits`, so neither folds away.
var hits: i32 = 0

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    fn op finally(self) { hits = hits * 3 + self.id }
}

@no_inline fn elided(a: i32) -> i32 {
    var r = Res(a)
    hits = hits * 5 + r.id
    r.finally()
    return hits
}

fn main() -> i32 {
    return elided(1)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: signed int elided(signed int a) noexcept {
// CXX-NOT: cleanup
// CXX: __k_s_r.__end();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.d/ir
// RUN: %FileCheck %s --check-prefix=IR < %t.d/ir/finally_opt.ll
// IR-LABEL: define {{.*}}6elidedEi(
// IR-NOT: br
// IR-NOT: live
// IR-NOT: __kairo_ul
// IR-NOT: alloca
// IR-NOT: call
// IR: mul{{.*}} 5
// IR-NOT: br
// IR: mul{{.*}} 3
// IR-NOT: br
// IR: ret i32
// IR-NEXT: }
