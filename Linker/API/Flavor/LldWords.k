/// --- The Kairo Project ---------------------------- Flavor/LldWords.k --- ///
///
///   The lld options every flavour passes so that LinkDiag can read lld's
///   output: every error (no limit, or the count stops matching what the
///   user sees), and no colour codes in the text it parses. The MinGW
///   driver has no colour option and lld-link spells the limit its own way.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub class LldWords {
    /// ld.lld, ld64.lld, wasm-ld and the MinGW driver.
    pub static fn no_error_limit() -> string {
        return "--error-limit=0"
    }

    /// lld-link's spelling of no_error_limit().
    pub static fn coff_no_error_limit() -> string {
        return "-errorlimit:0"
    }

    /// ld.lld, ld64.lld, wasm-ld (not the MinGW driver).
    pub static fn no_color() -> string {
        return "--color-diagnostics=never"
    }
}
