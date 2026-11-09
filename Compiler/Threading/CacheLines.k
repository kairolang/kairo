/// --- The Kairo Project ----------------------- Threading/CacheLines.k --- ///
///
///   The cache line size constant, for alignment.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// Cache line size detection for alignment. CACHE_LINE is a template
/// argument (PartitionQueue's SeqCell alignment), so it must stay a
/// compile-time constant.
///
eval if defined!(__APPLE__) && defined!(__aarch64__) {
    // Apple Silicon (M1/M2/M3+) uses 128-byte cache lines
    pub eval CACHE_LINE: usize = 128
} else if defined!(__powerpc64__) || defined!(__ppc64__) {
    // POWER / PPC64 - 128-byte lines
    pub eval CACHE_LINE: usize = 128
} else if defined!(__s390x__) {
    // IBM Z (s390x) - 256-byte lines
    pub eval CACHE_LINE: usize = 256
} else if defined!(__x86_64__) || defined!(__i386__) {
    // x86 / x86-64 - 64-byte lines
    pub eval CACHE_LINE: usize = 64
} else if defined!(__aarch64__) || defined!(__arm__) {
    // Non-Apple ARM (Cortex, Neoverse, etc.) - 64-byte lines
    pub eval CACHE_LINE: usize = 64
} else if defined!(__riscv) {
    // RISC-V - 64-byte lines on current profiles
    pub eval CACHE_LINE: usize = 64
} else if defined!(__wasm__) {
    // WebAssembly - no real cache hierarchy; 64 is a safe neutral
    pub eval CACHE_LINE: usize = 64
} else {
    // Conservative fallback
    pub eval CACHE_LINE: usize = 64
}
