// A prefix `...` with nothing to expand is still an error.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: error [S052E]: expected expression
fn Test() { sink(a, ...) }
