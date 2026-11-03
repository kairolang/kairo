// GAP / QUESTION G8: --syntax-only resolves imports, parses the whole import
// closure, and runs clang on ffi headers.
//   kairo --syntax-only --error-format=basic G8-syntax-only-parses-imports.k
//   -> R011E "failed to resolve import path 'Nowhere::X'"
// SELFHOST.md 5.1 assumes "syntax does not depend on any lower layer", and
// the flag's help says "stop after parsing and report only syntax errors".
// In the self-host run every input re-parsed its closure (78,723 duplicate
// diagnostics dropped; 30-60 s per Sema/Driver file, ~20 min for 308 files
// at 8 jobs), and the ffi "c++" imports of Compiler/Native/*.hh ran clang
// (CL001E 'include/core.hh' file not found -- the lib-helix runtime, 2.3).
// Either --syntax-only should stop before import resolution, or a separate
// parse-only mode is needed for 5.1.
import Nowhere::X

fn main() -> i32 { return 0 }
