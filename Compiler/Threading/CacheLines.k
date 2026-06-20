/// --- The Kairo Project ----------------------- Threading/CacheLines.k --- ///
///
///   Cache line size detection for alignment.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// Cache line size detection for alignment
///
/// \info in an inline "c++" block, since the current stage(0) parser
///       does not support static & eval variables, it only supports static
///       not even eval (constexpr) variables.
///
const eval if defined(__APPLE__) && defined(__aarch64__) {
    // Apple Silicon (M1/M2/M3+) uses 128-byte cache lines
    inline "c++" {
        static constexpr size_t CACHE_LINE = 128;
    }
} else if defined(__powerpc64__) || defined(__ppc64__) {
    // POWER / PPC64 - 128-byte lines
    inline "c++" {
        static constexpr size_t CACHE_LINE = 128;
    }
} else if defined(__s390x__) {
    // IBM Z (s390x) - 256-byte lines
    inline "c++" {
        static constexpr size_t CACHE_LINE = 256;
    }
} else if defined(__x86_64__) || defined(__i386__) {
    // x86 / x86-64 - 64-byte lines
    inline "c++" {
        static constexpr size_t CACHE_LINE = 64;
    }
} else if defined(__aarch64__) || defined(__arm__) {
    // Non-Apple ARM (Cortex, Neoverse, etc.) - 64-byte lines
    inline "c++" {
        static constexpr size_t CACHE_LINE = 64;
    }
} else if defined(__riscv) {
    // RISC-V - 64-byte lines on current profiles
    inline "c++" {
        static constexpr size_t CACHE_LINE = 64;
    }
} else if defined(__wasm__) {
    // WebAssembly - no real cache hierarchy; 64 is a safe neutral
    inline "c++" {
        static constexpr size_t CACHE_LINE = 64;
    }
} else {
    // Conservative fallback
    inline "c++" {
        static constexpr size_t CACHE_LINE = 64;
    }
}