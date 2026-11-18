// --error-format=json copies the bytes a message quotes as runs between the
// characters it escapes: non-ASCII text passes through whole, and each quote
// and backslash of the reason's spelling beside it is escaped. The same text emitted as a
// C++ string literal (octal escapes) prints back unchanged.
import std::io

@deprecated("naïve \"q\" a\\b\tcafé")
fn old() -> i32 { return 1 }

fn main() -> i32 {
    io::println("naïve \"q\" a\\b|café€")
    return old() - 1
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only --error-format=json 2>&1 || true; } | %FileCheck %s --check-prefix=JSON
// JSON: "code":"SC146W","message":"'old' is deprecated: naïve \\\"q\\\" a\\\\b\\tcafé"}
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: naïve "q" a\b|café€
