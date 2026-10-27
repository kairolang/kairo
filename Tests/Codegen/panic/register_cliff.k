// The register cliff (PANIC.md §1.1a): a panic result of at most 16 bytes
// whose payloads are trivially copied returns in two registers on x86-64
// SysV -- the tag and site word in one, the value in the other, the tag
// and site written as one 64-bit constant -- and a wider one through
// memory, which the OPT001R remark at the set's formation says.
struct Small { var code: i32 }
struct Wide { var a: i64; var b: i64 }
fn small(n: i32) panic(Small) -> i32 {
    if n < 0 { panic Small { code: n } }
    return n
}
fn wide(n: i32) panic(Wide) -> i32 {
    if n < 0 { panic Wide { a: 1, b: 2 } }
    return n
}
fn main() -> i32 {
    return (try small(3) catch => 0) + (try wide(4) catch => 0)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: register_cliff.k:12:4: remark [OPT001R]: 'Panic<i32, Wide>' is 24 bytes, so a function returning it returns through memory, not in two registers; its widest payload, 'Wide', is 16 bytes
// DIAG-NOT: remark
// REQUIRES: clang, llvm-objdump, host-x86_64, host-linux
// RUN: rm -rf %t.d
// RUN: %kairo %s -c -O2 --cache-dir %t.d
// RUN: %objdump -d --no-show-raw-insn %t.d/register_cliff.o | %FileCheck %s --check-prefix=ASM
// small: no store through a hidden pointer; the value goes back in edx.
// ASM-LABEL: <{{.*}}small{{.*}}>:
// ASM-NOT: (%rdi)
// ASM: movabsq
// ASM: ret
// wide: the result is written through the caller's pointer (rdi).
// ASM-LABEL: <{{.*}}wide{{.*}}>:
// ASM: (%rax)
