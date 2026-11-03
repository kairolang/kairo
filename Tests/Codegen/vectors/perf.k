// The `[T]` hot paths, linked -O2 for x86_64-linux-musl and read back from
// the object code, as Tests/alloc/perf.k reads the allocator's: `[]` is a
// bounds compare and a load (the trap is out of line), size / empty / back
// are loads, push_back with spare capacity makes no call (growth is a cold
// out-of-line call), pop_back and clear of an i32 vector have no loop, and
// `for x in v` is a pointer loop with no coroutine frame left.

@no_inline fn k_index(const v: [i32], i: usize) -> i32 { return v[i] }
@no_inline fn k_size(const v: [i32]) -> usize { return v.size() }
@no_inline fn k_empty(const v: [i32]) -> bool { return v.empty() }
@no_inline fn k_back(const v: [i32]) -> i32 { return *v.back() }
@no_inline fn k_push(@inout v: [i32], x: i32) { v.push_back(x) }
@no_inline fn k_pop(@inout v: [i32]) { v.pop_back() }
@no_inline fn k_clear(@inout v: [i32]) { v.clear() }
@no_inline fn k_sum(const v: [i32]) -> i32 {
    var t: i32 = 0
    for x in v { t += x }
    return t
}

fn main() -> i32 {
    var v: [i32]
    var i: i32 = 0
    while i < 10 { k_push(&v, i); i += 1 }
    k_pop(&v)
    var r = k_sum(v) + k_index(v, 2) + k_back(v) + (k_size(v) as i32)
    if k_empty(v) { return 1 }
    k_clear(&v)
    return r - (36 + 2 + 8 + 9)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, llvm-objdump, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// --no-icf: the checks name callees, and safe ICF (on above -O0) folds
// vector_out_of_range into any other function with the same code.
// RUN: %kairo %s --target=x86_64-linux-musl -O2 --no-icf -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %objdump -d --no-show-raw-insn %t.exe > %t.asm
// RUN: %FileCheck %s < %t.asm

// `[]`: one compare against len, the load; the trap is a cold call after
// the return.
// CHECK-LABEL: 7k_indexE{{.*}}>:
// CHECK-NEXT: cmpq 0x8(%rdi), %rsi
// CHECK-NEXT: jae
// CHECK-NEXT: movq (%rdi), %rax
// CHECK-NEXT: movl (%rax,%rsi,4), %eax
// CHECK-NEXT: retq
// CHECK-NEXT: pushq %rax
// CHECK-NEXT: callq {{.*}}vector_out_of_range

// size and empty are loads.
// CHECK-LABEL: 6k_sizeE{{.*}}>:
// CHECK-NEXT: movq 0x8(%rdi), %rax
// CHECK-NEXT: retq
// CHECK-LABEL: 7k_emptyE{{.*}}>:
// CHECK-NEXT: cmpq $0x0, 0x8(%rdi)
// CHECK-NEXT: sete %al
// CHECK-NEXT: retq

// back: the empty test, then the load.
// CHECK-LABEL: 6k_backE{{.*}}>:
// CHECK-NEXT: movq 0x8(%rdi), %rax
// CHECK-NEXT: testq %rax, %rax
// CHECK-NEXT: je
// CHECK-NEXT: movq (%rdi), %rcx
// CHECK-NEXT: movl -0x4(%rcx,%rax,4), %eax
// CHECK-NEXT: retq

// push_back with spare capacity: no frame, no call; a full vector is a
// conditional tail jump to the out-of-line push_grow.
// CHECK-LABEL: 6k_pushE{{.*}}>:
// CHECK-NEXT: movq 0x8(%rdi), %rax
// CHECK-NEXT: cmpq 0x10(%rdi), %rax
// CHECK-NEXT: je {{.*}}<{{.*}}9push_grow
// CHECK-NEXT: movq (%rdi), %rcx
// CHECK-NEXT: movl %esi, (%rcx,%rax,4)
// CHECK-NEXT: incq %rax
// CHECK-NEXT: movq %rax, 0x8(%rdi)
// CHECK-NEXT: retq

// pop_back and clear of a trivially destructible element: no loop.
// CHECK-LABEL: 5k_popE{{.*}}>:
// CHECK-NEXT: movq 0x8(%rdi), %rax
// CHECK-NEXT: testq %rax, %rax
// CHECK-NEXT: je
// CHECK-NEXT: decq %rax
// CHECK-NEXT: movq %rax, 0x8(%rdi)
// CHECK-NEXT: retq
// CHECK-LABEL: 7k_clearE{{.*}}>:
// CHECK-NEXT: movq $0x0, 0x8(%rdi)
// CHECK-NEXT: retq

// `for x in v`: `op in` is a generator, and clang elides its frame whole --
// no allocation, no resume call: a pointer loop, vectorized.
// CHECK-LABEL: 5k_sumE{{.*}}>:
// CHECK-NOT: call
// CHECK: paddd
// CHECK-NOT: call
// CHECK: retq
// CHECK-LABEL: <main>:
