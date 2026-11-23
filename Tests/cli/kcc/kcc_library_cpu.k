// The Kairo library a kcc link takes from the toolchain's cache (builtin,
// std and the runtime, built on first use) is compiled for the link's CPU,
// so the CPU is part of its key: a link for the baseline CPU does not take
// the library a -march=x86-64-v3 link built. Each CPU has its own library,
// and the baseline executable holds no AVX instruction although the
// x86-64-v3 library was built first, into the same cache.

import std::io

fn main() -> i32 {
    var parts: [string]
    for var i: i32 = 0; i < 40; ++i {
        parts.push(f"item {i}: {(i as f64) * 1.5}")
    }

    var total: usize = 0
    for var i: usize = 0; i < parts.size(); ++i {
        total += parts[i].size()
    }

    io::println(f"{total} bytes in {parts.size()} strings")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, host-x86_64, llvm-objdump
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %t.d && env KAIRO_CACHE_DIR=%t.d/cache %kcc -O2 -c %s -o %t.d/x.o
// RUN: cd %t.d && env KAIRO_CACHE_DIR=%t.d/cache %kcc -O2 -march=x86-64-v3 %t.d/x.o -o %t.d/v3
// RUN: cd %t.d && env KAIRO_CACHE_DIR=%t.d/cache %kcc -O2 %t.d/x.o -o %t.d/base
// RUN: %t.d/base | %FileCheck %s
// CHECK: 463 bytes in 40 strings
// RUN: test $(ls %t.d/cache/lib | wc -l) -eq 2
// RUN: %objdump -d --no-show-raw-insn %t.d/v3 > %t.d/v3.s
// RUN: %objdump -d --no-show-raw-insn %t.d/base > %t.d/base.s
// RUN: grep -q -e 'ymm[0-9]' %t.d/v3.s
// RUN: not grep -e 'ymm[0-9]' -e 'zmm[0-9]' %t.d/base.s
