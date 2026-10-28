// `thread` is a storage keyword of its own (variables.mdx), so `var thread`
// names two storage classes. It used to read "'thread' requires 'static'",
// from when `static thread` was the only spelling; `static thread` still
// parses, as `thread`.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: error [S045E]: 'var' cannot be combined with 'thread'
var thread BAD: i32 = 1
