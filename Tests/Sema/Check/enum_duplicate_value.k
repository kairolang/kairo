// Two variants of one enum may not share a value, however each value comes
// about: written, computed from earlier variants, or one past the previous.
// Only the later variant is an error, with a note at the first one holding
// the value. A combination of flags is legal as long as no OTHER variant has
// its value: `X = 3` in `Perms` is `R | W`, but nothing else is 3.

enum Written {
    A = 1,
    B = 1,
// DIAG:      enum_duplicate_value.k:[[@LINE-1]]:5: error [SC130E]: 'B' has the same value as 'A' (1)
// DIAG-NEXT: enum_duplicate_value.k:[[@LINE-3]]:5: note [SC130N]: 'A' is declared here
}

enum Implicit {
    A = 2,
    B = 1,
    C,
// DIAG:      enum_duplicate_value.k:[[@LINE-1]]:5: error [SC130E]: 'C' has the same value as 'A' (2)
// DIAG-NEXT: enum_duplicate_value.k:[[@LINE-4]]:5: note [SC130N]: 'A' is declared here
}

enum Computed derives u8 {
    R    = 1 << 0,
    W    = 1 << 1,
    RW   = 3,
    Both = R | W,
// DIAG:      enum_duplicate_value.k:[[@LINE-1]]:5: error [SC130E]: 'Both' has the same value as 'RW' (3)
// DIAG-NEXT: enum_duplicate_value.k:[[@LINE-3]]:5: note [SC130N]: 'RW' is declared here
}

enum Perms derives u8 { R = 1, W = 2, X = 3 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
