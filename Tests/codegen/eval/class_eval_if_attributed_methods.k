// An `eval if` in a class body, and at file scope, selects between two
// declarations of one function that differ in their attributes: the cold
// path is `@preserve_most` where LLVM has the convention (x86-64 and
// AArch64) and plain elsewhere. A class may also nest a `priv union` and
// hold a field of it.

class Buf {
    priv union Word {
        var ptr:  *u8?
        var bits: usize
    }

    var w: Self::Word
    var n: usize

    eval if defined!(__x86_64__) || defined!(__aarch64__) {
        @cold_path @preserve_most @no_inline priv fn grow(self, need: usize) { self.n = need }
    } else {
        @cold_path @no_inline priv fn grow(self, need: usize) { self.n = need }
    }

    fn Buf(self) {
        self.w.bits = 5
        self.n      = 0
    }

    fn fill(self) -> usize {
        self.grow(3)
        return self.n + self.w.bits
    }
}

eval if defined!(__x86_64__) || defined!(__aarch64__) {
    @cold_path @preserve_most @no_inline priv fn free_grow(need: usize) -> usize { return need }
} else {
    @cold_path @no_inline priv fn free_grow(need: usize) -> usize { return need }
}

fn main() -> i32 {
    var b = Buf()
    return (b.fill() + free_grow(1)) as i32 - 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --target=aarch64-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --target=riscv64-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %if sysroot-x86_64-windows-msvc %{ { %kairo %s --type-check-only --target=x86_64-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty %}
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang, sysroot-x86_64-linux-gnu, sysroot-aarch64-linux-gnu, sysroot-riscv64-linux-gnu
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --cache-dir %t.d/x86
// RUN: %FileCheck %s --check-prefix=MOST < %t.d/x86/class_eval_if_attributed_methods.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=aarch64-linux-gnu --cache-dir %t.d/a64
// RUN: %FileCheck %s --check-prefix=MOST < %t.d/a64/class_eval_if_attributed_methods.ll
// MOST-DAG: define {{.*}}preserve_mostcc {{.*}}3Buf4grow
// MOST-DAG: define {{.*}}preserve_mostcc {{.*}}9free_grow
// MOST-DAG: call preserve_mostcc {{.*}}3Buf4grow
// MOST-DAG: %"class.{{.*}}::Buf" = type { %"union.{{.*}}::Buf::Word", i64 }

// RUN: %kairo %s --emit=llvm-ir -O0 --target=riscv64-linux-gnu --cache-dir %t.d/rv
// RUN: %FileCheck %s --check-prefix=PLAIN < %t.d/rv/class_eval_if_attributed_methods.ll
// PLAIN-NOT: preserve_mostcc
// PLAIN: define {{.*}}3Buf4grow

// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
