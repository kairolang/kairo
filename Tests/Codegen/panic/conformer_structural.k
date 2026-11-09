// A STRUCTURAL conformer of a panicking requirement keeps its own result
//: a class that meets `T impl Src<A>` without declaring `impl` is
// not given the requirement's result by PanicLowering (one method may meet
// many interfaces), so its witness specialization converts what the member
// returns with `__kairo_pcall<R>`, as a widened `fn` value does. Before,
// the specialization returned `self->read(n)` as it was and clang rejected
// it ("no viable conversion from returned value of type 'int'"). Covered:
// a conformer that does not panic and one whose set is a strict subset,
// each through a generic bound, value and error paths.
struct A { var n: i32 }
struct B {}

interface <E> Src {
    fn read(self, n: i32) panic(E, B) -> i32
}

class Plain {
    fn read(self, n: i32) -> i32 { return n * 2 }
}

class Small {
    fn read(self, n: i32) panic(A) -> i32 {
        if n < 0 { panic A { n: n } }
        return n + 1
    }
}

fn <T impl Src<A>> total(a: T, n: i32) panic(A, B) -> i32 { return a.read(n) + 1 }

fn main() -> i32 {
    var p = Plain()
    var s = Small()
    var x = try total(p, 4) catch => -1
    var y = try total(s, 4) catch => -1
    var z = try total(s, -3) catch e: A => e.n catch => -1
    if x != 9 { return 1 }
    if y != 6 { return 2 }
    if z != -3 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s
// CHECK: struct Src_witness< ::conformer_structural::Plain,
// CHECK-NEXT: read(
// CHECK-NEXT: return::__kairo_pcall<{{.*}}>([&]() noexcept {
// CHECK-NEXT: return self->read(
