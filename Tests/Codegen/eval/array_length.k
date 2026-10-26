// An `eval` constant is a compile-time constant usable as an array length
// (eval.mdx, Usage as generic arguments: "including array sizes"), at file
// scope and in a function.
//
// XFAIL: *
// Ticket "[Codegen] An `eval` constant as an array length ICEs"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today it type-checks and
// then ICEs: "CXXSpell: type with no canonical reached codegen (sema gate
// failure)" at the global (the ticket saw EmitIR's "unresolved type" for a
// local). Until it is compiled it should at least be SC116E, not an
// ICE. When it XPASSes, delete the XFAIL -- the run below is already the
// real assertion.

eval N = 3
eval BUFFER_SIZE = 4

var buffer: [u8; BUFFER_SIZE]

fn main() -> i32 {
    var a: [i32; N] = [1, 2, 3]
    buffer[3] = 4
    return a[0] + a[1] + a[2] + (buffer[3] as i32)  // 6 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 10
