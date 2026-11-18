// A string literal at a C++ overload set with both `const char *` and a byte
// pointer (`const unsigned char *`, `const char8_t *`) binds `const char *`,
// as clang does: the literal is `const char[N]`, and no byte pointer is
// viable there. lets a literal reach `*const u8` as well, so both
// ranked Converted and tied (SC064E): self-host `llvm::outs() << "\n"`
// against raw_ostream's `<<(const char *)` and its deleted
// `<<(const char8_t *)`. A lone byte-pointer parameter still takes one.

ffi "c++" import "literal_vs_byte.h"

fn main() -> i32 {
    var r = pick("a")
    r += only_bytes("b")
    var s = Sink()
    s << "x"
    r += s.n
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 13
