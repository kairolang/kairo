import builtin::base::alloc::*

class P2 { var a: i64  var b: i64  fn P2(self, a: i64, b: i64) { self.a = a; self.b = b } }

static buf: [u8; 4096]
static cur: usize = 0
class Bump {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { var at = align_up(cur, align); cur = at + size; unsafe { return (&buf[0] as unsafe *u8) + at } }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Bump>(ptr, o, n, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    static fn enter() -> usize { return cur }
    static fn leave(m: usize) { cur = m }
    static fn range() -> (unsafe *u8, unsafe *u8) { unsafe { return (&buf[0] as unsafe *u8, (&buf[0] as unsafe *u8) + 4096) } }
}

@no_inline fn k_create() -> *P2 { return create<P2>(1i64, 2i64) }
@no_inline fn k_destroy(p: *P2) { destroy<P2>(p) }
@no_inline fn k_create_in() -> *P2 { return create_in<P2, System>(1i64, 2i64) }
@no_inline fn k_destroy_in(p: *P2) { destroy_in<P2, System>(p) }
@no_inline fn k_create_bump() -> *P2 { return create_in<P2, Bump>(1i64, 2i64) }
@no_inline fn k_scope_open_close() { var s = AllocatorScope<Bump>() }
@no_inline fn k_alloc_raw(n: usize) -> unsafe *u8 { return alloc_raw(n, 8) }
@no_inline fn k_free_raw(p: unsafe *u8, n: usize) { free_raw(p, n, 8) }

fn main() -> i32 {
    var *a = k_create(); k_destroy(a)
    var *b = k_create_in(); k_destroy_in(b)
    k_scope_open_close()
    var unsafe *r = k_alloc_raw(24); k_free_raw(r, 24)
    var *c = k_create_bump()
    return (c->a - 1) as i32
}

// --- lit wiring -----------------------------------------------------------
// The allocator's hot paths, linked -O2 for x86_64-linux-musl. Item 1 (TLS
// model): this is an executable link, so the user TU spells `scope_top` (a
// builtin `thread` global) local-exec at its extern declaration, and every
// read in a k_* function is one `%fs:<off>` operand -- no `__tls_get_addr`,
// and no `mov $off,%rax` first as initial-exec costs even once relaxed. The
// builtin's own TU stays initial-exec (its objects serve --shared links too).
// REQUIRES: clang, llvm-objdump, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %objdump -d --no-show-raw-insn %t.exe > %t.asm
// RUN: %FileCheck %s --check-prefix=TLS < %t.asm
// TLS-LABEL: 11free_scopedEPhmm>:
// TLS-NEXT: movq $-{{0x[0-9a-f]+}}, %rax
// TLS-NEXT: movq %fs:(%rax), %rax
// TLS-LABEL: 8k_createEv>:
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS: movq %fs:-{{0x[0-9a-f]+}}, %rax
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS-LABEL: 9k_destroyEP{{.*}}>:
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS: cmpq $0x0, %fs:-{{0x[0-9a-f]+}}
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS-LABEL: 11k_alloc_rawEm>:
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS: movq %fs:-{{0x[0-9a-f]+}}, %rax
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS-LABEL: 10k_free_rawEPhm>:
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS: cmpq $0x0, %fs:-{{0x[0-9a-f]+}}
// TLS-NOT: {{__tls_get_addr|%fs:\(}}
// TLS-LABEL: <main>:

// Item 2 (no EH landing pads): the runtime headers' declarations are
// noexcept (KAIRO_RT_NOEXCEPT), posix_memalign is called as noexcept, and
// `__kairo_fn`'s call operator is always-inline and noexcept, so nothing in
// the program references __clang_call_terminate at all -- which also keeps
// libc++abi's catch machinery out of the link. `oom` makes the handler's
// indirect call itself (one per representation: heap lambda, plain
// function), no out-of-line wrapper. Counts, with no scope open: k_create
// 12 (the push/pop pair is the stack alignment for the non-tail call to
// mi_malloc_small, not a TLS spill), k_destroy 3, k_create_in 9,
// k_destroy_in 1, k_create_bump 11 with no call. System is mimalloc
// (rt/mimalloc.c): a 16-byte, 8-aligned block takes the small-object entry
// points, mi_malloc_small and mi_free_small_nonnull, chosen at compile time.
// RUN: { ! grep -q __clang_call_terminate %t.asm; }
// RUN: %FileCheck %s --check-prefix=EH < %t.asm
// EH-LABEL: 9alloc_raw3oomEmm>:
// EH-NOT: callq {{.*}}<
// EH: callq *(%rcx)
// EH-NEXT: callq *(%rcx)
// EH-NEXT: {{nop|int3}}
// EH-NOT: _ZNK10__kairo_fn
// EH-LABEL: 8k_createEv>:
// EH-NEXT: pushq %rax
// EH-NEXT: movq %fs:-{{0x[0-9a-f]+}}, %rax
// EH-NEXT: movl $0x10, %edi
// EH-NEXT: testq %rax, %rax
// EH-NEXT: jne
// EH-NEXT: callq {{.*}}<mi_malloc_small>
// EH-NEXT: testq %rax, %rax
// EH-NEXT: je
// EH-NEXT: movq $0x1, (%rax)
// EH-NEXT: movq $0x2, 0x8(%rax)
// EH-NEXT: popq %rcx
// EH-NEXT: retq
// EH-LABEL: 9k_destroyEP{{.*}}>:
// EH-NEXT: cmpq $0x0, %fs:-{{0x[0-9a-f]+}}
// EH-NEXT: jne
// EH-NEXT: jmp {{.*}}<mi_free_small_nonnull>
// EH-NOT: {{pushq|popq}}
// EH-LABEL: 11k_create_inEv>:
// EH-NEXT: pushq %rax
// EH-NEXT: movl $0x10, %edi
// EH-NEXT: callq {{.*}}<mi_malloc_small>
// EH-NEXT: testq %rax, %rax
// EH-NEXT: je
// EH-NEXT: movq $0x1, (%rax)
// EH-NEXT: movq $0x2, 0x8(%rax)
// EH-NEXT: popq %rcx
// EH-NEXT: retq
// EH-LABEL: 12k_destroy_inEP{{.*}}>:
// EH-NEXT: jmp {{.*}}<mi_free_small_nonnull>
// EH-LABEL: 13k_create_bumpEv>:
// EH-NOT: call
// EH: retq
// EH-LABEL: 11k_alloc_rawEm>:
// EH-NOT: pushq
// EH: jmpq *%rax
// EH-LABEL: 10k_free_rawEPhm>:
// EH-NOT: pushq
// EH: jmp {{.*}}<{{.*}}free_scoped
// EH-LABEL: <main>:
