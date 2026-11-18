// --emit validates its value in the driver, before any compile work: an
// unknown value is a hard error with a driver-level (location-less)
// diagnostic, so a typo cannot silently fall through to a default object
// compile. The not-yet-implemented kinds (tokens, ast, sema, bcir, cxx,
// dep-info) are not pinned here: they are advertised in --help and will
// start working one by one; see HELP_AUDIT.md.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --emit=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BOGUS
// BOGUS: error [U003E]: invalid --emit value 'bogus'; accepted: obj, asm, llvm-ir, llvm-bc

