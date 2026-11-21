/// --- The Kairo Project ------------------------------ Native/Shims.k --- ///
///
///   The build-wide counters, the exact-bytes file write and the f8
///   literal encoder: the parts of the Native shims that are ordinary
///   code. Native/Shims.hh keeps the spellings Kairo has no syntax for
///   (macros, `volatile`, `struct stat`, the weakly linked heap census).
///
///   The counters are function-local statics of inline functions: one
///   instance program-wide however many modules inline them.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh" // Atomic
ffi "c++" import "llvm/ADT/APFloat.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Error.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "system_error"

import std::c_char

/// Uses of a header set's clang AST after it was released early
/// (HeaderSet::_note_late). Expected 0; the driver reports a nonzero count.
pub inline fn header_set_late_uses() -> unsafe *kairo::std::Atomic<u64> {
    static n: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    return unsafe &n
}

/// -finfer-purity's totals over the build (FnPurityCheck::settle, one add per
/// TU, from the Sema pool); --print-stats reports them.
pub inline fn purity_inferred_const() -> unsafe *kairo::std::Atomic<u64> {
    static n: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    return unsafe &n
}

pub inline fn purity_inferred_pure() -> unsafe *kairo::std::Atomic<u64> {
    static n: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    return unsafe &n
}

/// Inferred levels the termination proof took away (FnPurityCheck::settle):
/// for a loop in the function's own body, and for a call (a callee not
/// proven, or a call cycle).
pub inline fn purity_unproven_loop() -> unsafe *kairo::std::Atomic<u64> {
    static n: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    return unsafe &n
}

pub inline fn purity_unproven_call() -> unsafe *kairo::std::Atomic<u64> {
    static n: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    return unsafe &n
}

/// Header sets re-parsed after HeaderSet::release_unused.
pub inline fn header_set_revivals() -> unsafe *kairo::std::Atomic<u64> {
    static n: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    return unsafe &n
}

/// `text` written to `path` byte for byte: no newline translation on any
/// host. llvm::sys::writeFileWithEncoding writes in text mode, so on Windows
/// every '\n' becomes "\r\n" while LinkFS::read hands bytes back as they are;
/// the Kairo library's manifest reads back paths ending in '\r'.
pub fn write_file_exact(path: llvm::StringRef, text: llvm::StringRef) -> bool {
    var ec = cxx::std::error_code()
    var os = llvm::raw_fd_ostream(path, &ec, llvm::sys::fs::OF_None)
    if ec.value() != 0 {
        return false
    }

    os.write(text.data(), text.size())
    os.close()
    // The stream's destructor ends the process when the error flag is still
    // set, so the flag is read and cleared here: a failed write is the
    // caller's to report.
    const failed = os.has_error()
    os.clear_error()
    return !failed
}

/// The f8e4m3 (`e5m2` false: OCP E4M3FN) or f8e5m2 encoding of a float
/// literal's digits `s[0..n)` (decimal, or `0x` hex with its `p`
/// exponent; no separators, no suffix), rounded ONCE to nearest even, as
/// clang rounds a literal at its own type: EmitIR emits an f8 literal as
/// its class's `from_bits(<this>)` since no C++ literal has the
/// format and a double literal would round twice. E4M3FN has no infinity:
/// an overflow saturates to +/-448, Kairo's rule (std/rt/Float8.k), where
/// APFloat would give NaN. -1 when APFloat does not read the digits.
pub fn f8_literal_bits(s: unsafe *const u8, n: usize, e5m2: bool) -> i32 {
    var v = llvm::APFloat(
        if e5m2 => llvm::APFloat::Float8E5M2() else => llvm::APFloat::Float8E4M3FN(),
    )

    var st = v.convertFromString(
        llvm::StringRef(unsafe (s as unsafe *const c_char), n),
        llvm::RoundingMode::NearestTiesToEven,
    )

    if !(st as bool) {
        llvm::consumeError(st.takeError())
        return -1
    }

    if !e5m2 && ((st.get() as u32) & (llvm::APFloat::opOverflow as u32)) != 0 {
        return if v.isNegative() => 0xFE else => 0x7E
    }

    return v.bitcastToAPInt().getZExtValue() as i32
}
