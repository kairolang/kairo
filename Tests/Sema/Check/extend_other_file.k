// The same-file rule for `extend` (extends.mdx, Same-File Restriction): a
// plain `extend` must be in the type's file, and an `extend ... impl` in
// the type's file or the interface's. Inputs/extend_other_file/main.k
// breaks both: it extends point.k's Point (line 3), and makes it conform to
// show.k's Show (line 4).
//
// XFAIL: *
// Ticket "[Sema] The same-file rule for `extend` is not checked"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26; status.mdx, Not Diagnosed).
// Today both blocks are accepted without a word. The code is not decided;
// the checks ask for an error at each `extend`. When it XPASSes, delete the
// XFAIL and pin the code and message.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/extend_other_file && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: main.k:3:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
// CHECK: main.k:4:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
