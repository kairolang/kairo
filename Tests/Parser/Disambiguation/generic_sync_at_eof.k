// A generic-argument list that fails to parse is skipped by
// _sync_generic_args. Its loop read `while !eof && consumed < 64`, which
// Stage 0 compiles as `!(eof && consumed < 64)`: once 64 tokens had been
// skipped and the cursor sat at end of file (where advance() no longer
// moves), the loop never ended. The trigger is an unknown name, `<`, an
// argument that fails (`<` here), then at least 64 tokens to EOF with no
// `;`, `)`, `]`, `}` or `>` among them: the line below. Before the fix this
// file never finished; it now parses in well under a second. lit has no
// per-test timeout, so a regression shows as a hung run.
//
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s
// CHECK: generic_sync_at_eof.k:[[@LINE+3]]:12: error [S052E]: expected expression, found '<'
// CHECK-NOT: error

DenseSet < < DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet DenseSet
