// --emit accepts exactly obj, asm, llvm-ir and llvm-bc. Every other value,
// including the names the help used to advertise (tokens, ast, ...), is one
// error naming that same set, so the help and the diagnostic cannot disagree.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --emit=tokens 2>&1 || true; } | %FileCheck %s --check-prefix=TOK
// TOK: error [U003E]: invalid --emit value 'tokens'; accepted: obj, asm, llvm-ir, llvm-bc
// RUN: { %kairo %s --emit=nonsense 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid --emit value 'nonsense'; accepted: obj, asm, llvm-ir, llvm-bc
// RUN: %kairo --help | %FileCheck %s --check-prefix=HELP
// HELP: obj,asm,llvm-ir,llvm-bc
