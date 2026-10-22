// An identifier imported from a C++ header is interned through
// ASTContext::make_token, whose hash panicked at 256 chars or more ("String
// too long for hashing") -- C++ headers (libc++, MinGW) carry identifiers
// that long, so importing one killed the compiler. The lexer hashed a Kairo
// identifier of any length; the two now agree.

ffi "c++" import "long_ident.h"

fn call(x: i32) -> i32 {
    return very_long_name_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx(x)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|fatal|panic|crash}}
