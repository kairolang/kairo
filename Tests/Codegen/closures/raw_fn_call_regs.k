// A call through a raw `unsafe fn` field passes its arguments in registers
// (P231). ScopeFrame (Lib/builtin/base/alloc.k) holds its allocator's
// functions as `unsafe fn` pointers, so `f->alloc(size, align)` is one
// indirect call with `size` and `align` moved into the argument registers.
// As `fn` values (`__kairo_fn`, three words) the same call loaded the
// object word, branched on it, and spilled both arguments to the stack to
// pass their addresses (`A&&...`) to the ops table.

import builtin::base::alloc::ScopeFrame

@noinline fn through_frame(f: unsafe *ScopeFrame, size: usize, align: usize) -> unsafe *u8 {
    unsafe { return f->alloc(size, align) }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, llvm-objdump
// RUN: rm -rf %t.d
// RUN: { %kairo %s --target=x86_64-linux-musl -c -O2 --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: %objdump -d --no-show-raw-insn %t.d/raw_fn_call_regs.o | awk '/through_frame.*>:/,/^$/' > %t.asm
// RUN: %FileCheck %s --check-prefix=ASM < %t.asm
// ASM: through_frame
// ASM-NOT: (%rsp)
// ASM-NOT: test
// ASM: movq %rsi, %rdi
// ASM-NEXT: movq %rdx, %rsi
// ASM-NEXT: callq *(%rax)
// ASM-NOT: (%rsp)
// ASM-NOT: callq *
