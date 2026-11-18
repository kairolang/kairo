// rule: a TU with no ffi import binds no `cxx` at all. Not a reserved word,
// not a keyword, not a name the compiler keeps alive -- an ordinary miss, so
// a file that never touched C++ pays nothing for the overlay existing.

fn no_cxx() -> void {
    var s: cxx::std::string
}

// --- lit wiring -----------------------------------------------------------
// The miss is the ordinary unknown-type-name error on the HEAD segment, not
// R053E: there is nothing named `cxx` here to have used wrongly.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: R021E
// DIAG-SAME: cxx
// DIAG-NOT: R053E
