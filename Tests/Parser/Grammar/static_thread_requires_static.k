// `thread` is thread-local storage, which has static storage duration.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: error [S045E]: 'thread' requires 'static'
var thread BAD: i32 = 1
