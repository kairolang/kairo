// A C++ call can only leave out TRAILING defaults.
ffi "c++" import "defs.hh"

fn bad() -> i32 {
    return span3(1, c: 9)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: ffi_defaults_skip.k:5:{{[0-9]+}}: error [SC107E]: parameter 'c' is given but 'b' before it is left to its C++ default
