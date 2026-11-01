// `@preserve_most`, `@preserve_all` and `@preserve_none` are LLVM's
// preserve_mostcc / preserve_allcc / preserve_nonecc on every declaration
// and call, and a TU that defines or calls one carries the ABI note kld
// reads (format 1, the convention bitset, the LLVM major).
//
// What preserve_most buys: `hot_most` keeps six integers live across a
// call. Against a callee that preserves the argument registers, they stay
// where they are; against a plain callee, the same caller must move them to
// callee-saved registers and save those in its prologue. The callees are
// recursive, so the optimizer cannot inline them away.

@preserve_most
priv fn slow_most(n: u64) -> u64 {
    if n < 2 { return n }
    return slow_most(n - 1) + slow_most(n - 2)
}

priv fn slow_plain(n: u64) -> u64 {
    if n < 2 { return n }
    return slow_plain(n - 1) + slow_plain(n - 2)
}

@preserve_all
priv fn slow_fp(x: f64) -> f64 { return x * 2.0 }

@preserve_none
priv fn dispatch(n: u64) -> u64 { return n + 1 }

fn hot_most(a: u64, b: u64, c: u64, d: u64, e: u64, f: u64) -> u64 {
    var s = slow_most(a)
    return s + a * b + c * d + e * f
}

fn hot_plain(a: u64, b: u64, c: u64, d: u64, e: u64, f: u64) -> u64 {
    var s = slow_plain(a)
    return s + a * b + c * d + e * f
}

fn main() -> i32 {
    var r = hot_most(5, 1, 2, 3, 4, 5) + hot_plain(5, 1, 2, 3, 4, 5) + dispatch(1)
    if slow_fp(1.5) != 3.0 { return 1 }
    if r != 74 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: __attribute{{(__)?}}((preserve_most)){{.*}}slow_most(
// CXX-DAG: __attribute{{(__)?}}((preserve_all)){{.*}}slow_fp(
// CXX-DAG: __attribute{{(__)?}}((preserve_none)){{.*}}dispatch(
// CXX-DAG: gnu::section("__kairo_abi"){{.*}}__kairo_abi_note[] = {
// CXX-DAG: 0x7f, 0x4b, 0x41, 0x42, 0x49, 1, 7, {{[1-9][0-9]*}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --cache-dir %t.d/x86
// RUN: %FileCheck %s --check-prefix=IR < %t.d/x86/callconv.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=aarch64-linux-gnu --cache-dir %t.d/a64
// RUN: %FileCheck %s --check-prefix=IR < %t.d/a64/callconv.ll
// IR-DAG: define {{.*}}preserve_mostcc {{.*}}slow_most
// IR-DAG: define {{.*}}preserve_allcc {{.*}}slow_fp
// IR-DAG: define {{.*}}preserve_nonecc {{.*}}dispatch
// IR-DAG: call preserve_mostcc {{.*}}slow_most
// IR-DAG: call preserve_nonecc {{.*}}dispatch
// IR-DAG: __kairo_abi_note{{[^ ]*}} = internal constant [8 x i8] c"\7FKABI\01\07{{.*}}", section "__kairo_abi"

// RUN: %kairo %s --emit=asm -O2 -c --target=x86_64-linux-gnu -o %t.x86.s --cache-dir %t.d/x86s
// RUN: %FileCheck %s --check-prefix=X86 < %t.x86.s
// X86-LABEL: {{^_ZN.*}}8hot_most{{.*}}:
// X86-NOT: %r{{(bx|bp|12|13|14|15)}}
// X86: callq {{.*}}slow_most
// X86-NOT: %r{{(bx|bp|12|13|14|15)}}
// X86: ret
// X86-LABEL: {{^_ZN.*}}9hot_plain{{.*}}:
// X86: pushq %r{{(bx|bp|12|13|14|15)}}
// X86: callq {{.*}}slow_plain

// RUN: %kairo %s --emit=asm -O2 -c --target=aarch64-linux-gnu -o %t.a64.s --cache-dir %t.d/a64s
// RUN: %FileCheck %s --check-prefix=A64 < %t.a64.s
// A64-LABEL: {{^_ZN.*}}8hot_most{{.*}}:
// A64-NOT: {{x19|x2[0-8]}}
// A64: bl {{.*}}slow_most
// A64-NOT: {{x19|x2[0-8]}}
// A64: ret
// A64-LABEL: {{^_ZN.*}}9hot_plain{{.*}}:
// A64: {{stp|str}} {{.*}}x{{(19|2[0-8])}}
// A64: bl {{.*}}slow_plain

// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
