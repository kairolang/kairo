// --emit-headers DIR writes the generated headers into DIR, creating it. The
// builtin header is always written; this file's own header is not requested.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.hdr
// RUN: %kairo %s --type-check-only --emit-headers %t.hdr
// RUN: test -f %t.hdr/builtin.hh
// RUN: not test -e %t.hdr/emit_headers.hh
