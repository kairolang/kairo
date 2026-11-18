// The owning string's hot paths, linked -O2 for x86_64-linux-musl, pinned
// by instruction. Each k_* is one operation behind @no_inline so its code
// can be read on its own.

@no_inline fn k_lit() -> string { return "hello" }
@no_inline fn k_copy(const s: string) -> string { return s }
@no_inline fn k_size(const s: string) -> usize { return s.size() }
@no_inline fn k_empty(const s: string) -> bool { return s.empty() }
@no_inline fn k_index(const s: string, i: usize) -> u8 { return s[i] }
@no_inline fn k_push(s: *string, c: u8) { s->push_back(c) }
@no_inline fn k_append(s: *string, const t: string) { (*s) += t }
@no_inline fn k_eq(const a: string, const b: string) -> bool { return a == b }
@no_inline fn k_lt(const a: string, const b: string) -> bool { return a < b }
@no_inline fn k_drop(s: *string) { var t = (*s) }

fn main() -> i32 {
    var a = k_lit()
    var b = k_copy(a)
    var s = string()
    for var i: usize = 0; i < 100; ++i { k_push(&s, 97); k_append(&s, b) }
    k_drop(&s)
    var r: usize = 0
    if k_eq(a, b) { r += 1 }
    if k_lt(s, a) { r += 1 }
    if !k_empty(s) { r += 1 }
    return (k_size(s) / 100 + r + k_index(s, 0) as usize - 97) as i32   // 6 + 3 == 9
}

// --- lit wiring -----------------------------------------------------------
// Instruction pins, x86_64-linux-musl -O2 (as Tests/alloc/perf.k):
//   k_lit    a literal is four stores: no call, no allocation.
//   k_copy   copying a borrowed string is a 32-byte copy and one test of
//            cap; the deep copy (own_exact_) is out of line.
//   k_size / k_empty / k_index   one load (and a compare / a second load).
//   k_push   push_back with room: 12 instructions, no frame, no call; the
//            growth path is a tail call.
//   k_append `+=` with room: one call, memcpy; growth is a tail call.
//   k_eq     `==` derived from `<=>`: the length test first, then pointer
//            identity (copies of one literal), then one bcmp; the
//            unequal-length path's memcmp is gone.
//   k_drop   a copy of a borrowed string, then its destructor: no call.
// REQUIRES: clang, llvm-objdump, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
// RUN: %objdump -d --no-show-raw-insn %t.exe > %t.asm
// RUN: %FileCheck %s --check-prefix=PIN < %t.asm
// PIN-LABEL: 5k_litEv>:
// PIN-NEXT: movq %rdi, %rax
// PIN-NEXT: leaq {{.*}}(%rip), %rcx
// PIN-NEXT: movq %rcx, (%rdi)
// PIN-NEXT: movq $0x5, 0x8(%rdi)
// PIN-NEXT: movq $0x5, 0x10(%rdi)
// PIN-NEXT: movq $0x0, 0x18(%rdi)
// PIN-NEXT: retq
// PIN-LABEL: 6k_copyER{{.*}}>:
// PIN-NEXT: movq $0x0, 0x18(%rdi)
// PIN-NEXT: movq (%rsi), %rax
// PIN-NEXT: movq %rax, (%rdi)
// PIN-NEXT: movups 0x8(%rsi), %xmm0
// PIN-NEXT: movups %xmm0, 0x8(%rdi)
// PIN-NEXT: cmpq $0x0, 0x18(%rsi)
// PIN-NEXT: jne
// PIN-NEXT: movq %rdi, %rax
// PIN-NEXT: retq
// PIN: callq {{.*}}10own_exact_Ev>
// PIN-LABEL: 6k_sizeER{{.*}}>:
// PIN-NEXT: movq 0x8(%rdi), %rax
// PIN-NEXT: retq
// PIN-LABEL: 7k_emptyER{{.*}}>:
// PIN-NEXT: cmpq $0x0, 0x8(%rdi)
// PIN-NEXT: sete %al
// PIN-NEXT: retq
// PIN-LABEL: 7k_indexER{{.*}}>:
// PIN-NEXT: movq (%rdi), %rax
// PIN-NEXT: movzbl (%rax,%rsi), %eax
// PIN-NEXT: retq
// PIN-LABEL: 6k_pushEP{{.*}}>:
// PIN-NEXT: movq 0x8(%rdi), %rax
// PIN-NEXT: leaq 0x1(%rax), %rcx
// PIN-NEXT: cmpq 0x18(%rdi), %rcx
// PIN-NEXT: jae
// PIN-NEXT: movq (%rdi), %rdx
// PIN-NEXT: movb %sil, (%rdx,%rax)
// PIN-NEXT: movb $0x0, 0x1(%rdx,%rax)
// PIN-NEXT: movq %rcx, 0x8(%rdi)
// PIN-NEXT: xorl %eax, %eax
// PIN-NEXT: cmpb $-0x40, %sil
// PIN-NEXT: setge %al
// PIN-NEXT: addq %rax, 0x10(%rdi)
// PIN-NEXT: retq
// PIN-NEXT: movzbl %sil, %esi
// PIN-NEXT: jmp {{.*}}10push_slow_Eh>
// PIN-LABEL: 8k_appendEP{{.*}}>:
// PIN-NOT: callq
// PIN: callq {{.*}}<memcpy>
// PIN-NOT: callq
// PIN: retq
// PIN-NOT: callq
// PIN: jmp {{.*}}12append_slow_E{{.*}}>
// PIN-LABEL: 4k_eqER{{.*}}>:
// PIN-NEXT: movq 0x8(%rdi), %rdx
// PIN-NEXT: cmpq 0x8(%rsi), %rdx
// PIN-NEXT: jne
// PIN-NEXT: movq (%rdi), %rdi
// PIN-NEXT: movq (%rsi), %rsi
// PIN-NEXT: cmpq %rsi, %rdi
// PIN-NEXT: je
// PIN-NEXT: pushq %rax
// PIN-NEXT: callq {{.*}}<bcmp>
// PIN-NEXT: testl %eax, %eax
// PIN-NEXT: sete %al
// PIN-LABEL: 6k_dropEP{{.*}}>:
// PIN: cmpq $0x0, 0x18(%rdi)
// PIN-NEXT: jne
// PIN-NEXT: addq $0x28, %rsp
// PIN-NEXT: retq
