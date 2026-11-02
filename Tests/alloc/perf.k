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
// model): `scope_top` (a builtin `thread` global) is initial-exec, so every
// read is a GOT-free `%fs:` load once the linker relaxes it -- never a
// `__tls_get_addr` call with the register saves around it.
// REQUIRES: clang, llvm-objdump, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %objdump -d --no-show-raw-insn %t.exe > %t.asm
// RUN: %FileCheck %s --check-prefix=TLS < %t.asm
// TLS-LABEL: 8k_createEv>:
// TLS-NOT: __tls_get_addr
// TLS: movq %fs:(%rax), %rax
// TLS-NOT: __tls_get_addr
// TLS-LABEL: 9k_destroyEP{{.*}}>:
// TLS-NOT: __tls_get_addr
// TLS: movq %fs:(%rax), %rax
// TLS-NOT: __tls_get_addr
// TLS-LABEL: 11k_alloc_rawEm>:
// TLS-NOT: __tls_get_addr
// TLS: movq %fs:(%rax), %rax
// TLS-NOT: __tls_get_addr
// TLS-LABEL: 10k_free_rawEPhm>:
// TLS-NOT: __tls_get_addr
// TLS: movq %fs:(%rax), %rax
// TLS-NOT: __tls_get_addr
// TLS-LABEL: <main>:

// Item 2 (no EH landing pads after indirect calls): with the function-
// pointer types noexcept, no k_* function and no `oom` references
// __clang_call_terminate, and each hot path is pinned whole. Counts, with no
// scope open: k_create 13 (the push/pop pair is the stack alignment for the
// non-tail call to malloc, not a TLS spill), k_destroy 4, k_create_in 9,
// k_destroy_in 1, k_create_bump 11 with no call, k_scope_open_close 0.
// RUN: %FileCheck %s --check-prefix=EH < %t.asm
// EH-LABEL: alloc3oomEmm>:
// EH-NOT: __clang_call_terminate
// EH: callq {{.*}}<_ZNK10__kairo_fnIFvmmEEclEmm>
// EH-NEXT: {{: (nop|int3)}}
// EH-LABEL: <_ZNK10__kairo_fnIFvmmEEclEmm>:
// EH-NOT: __clang_call_terminate
// EH: jmpq *%rax
// EH-LABEL: 8k_createEv>:
// EH-NEXT: pushq %rax
// EH-NEXT: movq $-{{0x[0-9a-f]+}}, %rax
// EH-NEXT: movq %fs:(%rax), %rax
// EH-NEXT: movl $0x10, %edi
// EH-NEXT: testq %rax, %rax
// EH-NEXT: jne
// EH-NEXT: callq {{.*}}<malloc>
// EH-NEXT: testq %rax, %rax
// EH-NEXT: je
// EH-NEXT: movq $0x1, (%rax)
// EH-NEXT: movq $0x2, 0x8(%rax)
// EH-NEXT: popq %rcx
// EH-NEXT: retq
// EH-NOT: __clang_call_terminate
// EH-LABEL: 9k_destroyEP{{.*}}>:
// EH-NEXT: movq $-{{0x[0-9a-f]+}}, %rax
// EH-NEXT: movq %fs:(%rax), %rax
// EH-NEXT: testq %rax, %rax
// EH-NEXT: je {{.*}}<free>
// EH-NOT: {{pushq|popq|__clang_call_terminate}}
// EH-LABEL: 11k_create_inEv>:
// EH-NEXT: pushq %rax
// EH-NEXT: movl $0x10, %edi
// EH-NEXT: callq {{.*}}<malloc>
// EH-NEXT: testq %rax, %rax
// EH-NEXT: je
// EH-NEXT: movq $0x1, (%rax)
// EH-NEXT: movq $0x2, 0x8(%rax)
// EH-NEXT: popq %rcx
// EH-NEXT: retq
// EH-NOT: __clang_call_terminate
// EH-LABEL: 12k_destroy_inEP{{.*}}>:
// EH-NEXT: jmp {{.*}}<free>
// EH-LABEL: 13k_create_bumpEv>:
// EH-NOT: call
// EH: retq
// EH-LABEL: 18k_scope_open_closeEv>:
// EH-NEXT: retq
// EH-LABEL: 11k_alloc_rawEm>:
// EH-NOT: {{pushq|__clang_call_terminate}}
// EH: jmpq *%rax
// EH-LABEL: 10k_free_rawEPhm>:
// EH-NOT: {{pushq|__clang_call_terminate}}
// EH: jmpq *%rax
// EH-LABEL: <main>:
