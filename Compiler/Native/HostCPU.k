/// --- The Kairo Project ----------------------------- Native/HostCPU.k --- ///
///
///   The CPU this compiler runs on, as LLVM reports it: its name, the
///   features it has, and the x86-64 microarchitecture level those
///   features reach. A build for the host machine targets this CPU
///   (CompilerInstance::_apply_host_cpu).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/TargetParser/Host.h"

import std::io

/// LLVM's name for the host CPU (`znver4`, `apple-m1`); `generic` when
/// LLVM does not recognise it.
pub fn host_cpu_name() -> string {
    var n = llvm::sys::getHostCPUName()
    return string(
        unsafe ((n.data() as unsafe *const u8) as *const u8),
        n.size(),
    )
}

/// The features the host CPU has and the OS lets a program use (AVX-512
/// only where the OS saves its state), by LLVM's names. Sorted, so a key
/// made from the list does not follow the StringMap's hash order.
pub fn host_cpu_features() -> [string] {
    var out: [string]
    var map           = llvm::sys::getHostCPUFeatures()
    for var it = map.begin(); it != map.end(); ++it {
        if it->getValue() {
            var k = it->getKey()
            out.push(
                string(
                    unsafe ((k.data() as unsafe *const u8) as *const u8),
                    k.size(),
                ),
            )
        }
    }

    out.sort()
    return out
}

fn _has_all(const have: [string], const want: [string]) -> bool {
    for var i: usize = 0; i < want.size(); ++i {
        var found = false
        for var j: usize = 0; j < have.size(); ++j {
            if have[j] == want[i] {
                found = true
            }
        }

        if !found {
            return false
        }
    }

    return true
}

/// The highest x86-64 microarchitecture level whose features are all in
/// `feats`: 1 is the baseline every x86-64 CPU has, 2 to 4 are the psABI's
/// x86-64-v2, -v3 and -v4. The feature sets are LLVM's for the CPUs of
/// those names (X86TargetParser's FeaturesX86_64_V2..V4). A level counts
/// only on top of the one below it.
pub fn x86_64_level(const feats: [string]) -> u32 {
    var v2: [string]
    v2.push("cx16")
    v2.push("popcnt")
    v2.push("sahf")
    v2.push("sse3")
    v2.push("sse4.1")
    v2.push("sse4.2")
    v2.push("ssse3")
    if !_has_all(feats, v2) {
        return 1
    }

    var v3: [string]
    v3.push("avx")
    v3.push("avx2")
    v3.push("bmi")
    v3.push("bmi2")
    v3.push("f16c")
    v3.push("fma")
    v3.push("lzcnt")
    v3.push("movbe")
    v3.push("xsave")
    if !_has_all(feats, v3) {
        return 2
    }

    var v4: [string]
    v4.push("avx512bw")
    v4.push("avx512cd")
    v4.push("avx512dq")
    v4.push("avx512f")
    v4.push("avx512vl")
    if !_has_all(feats, v4) {
        return 3
    }

    return 4
}

/// The CPU name clang and LLVM give `level` (x86_64_level's result).
pub fn x86_64_level_name(level: u32) -> string {
    if level <= 1 {
        return "x86-64"
    }

    return f"x86-64-v{level}"
}

fn _split_words(const s: string) -> [string] {
    var out: [string]
    var cur           = ""
    for var i: usize = 0; i < s.size(); ++i {
        var c = s.data()[i]
        if c == (' ' as u8) {
            if !cur.is_empty() {
                out.push(cur.copy())
                cur = ""
            }
        } else {
            cur.push(c)
        }
    }

    if !cur.is_empty() {
        out.push(cur.copy())
    }

    return out
}

fn _expect_level(const feats: string, want: u32) -> i32 {
    var got = x86_64_level(_split_words(feats))
    if got == want {
        return 0
    }

    io::println(f"x86_64_level({feats}) = {got}, expected {want}")
    return 1
}

/// The level ladder on fixed feature lists: each level, a list one feature
/// short of the next level, and a higher level's features without the level
/// below them.
pub fn Test() -> i32 {
    var base = "cmov cx8 fxsr mmx sse sse2"
    var v2   = base.copy() + " cx16 popcnt sahf sse3 sse4.1 sse4.2 ssse3"
    var v3 = v2.copy() + " avx avx2 bmi bmi2 f16c fma lzcnt movbe xsave"
    var v4          = v3.copy() + " avx512bw avx512cd avx512dq avx512f avx512vl"
    var failed: i32 = 0
    failed += _expect_level("", 1)
    failed += _expect_level(base, 1)
    failed += _expect_level(
        base.copy() + " cx16 popcnt sse3 sse4.1 sse4.2 ssse3",
        1,
    )

    failed += _expect_level(v2, 2)
    failed += _expect_level(
        v2.copy() + " avx avx2 bmi bmi2 f16c lzcnt movbe xsave",
        2,
    )

    failed += _expect_level(v3, 3)
    failed += _expect_level(v3.copy() + " avx512f avx512cd", 3)
    failed += _expect_level(v4, 4)
    failed += _expect_level(
        base.copy() + " avx avx2 bmi bmi2 f16c fma lzcnt movbe xsave",
        1,
    )

    failed += _expect_level(
        v2.copy() + " avx512bw avx512cd avx512dq avx512f avx512vl",
        2,
    )

    if x86_64_level_name(1) != "x86-64" || x86_64_level_name(3) != "x86-64-v3" {
        io::println("x86_64_level_name: wrong name for level 1 or 3")
        failed += 1
    }

    return failed
}
