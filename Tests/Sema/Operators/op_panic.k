// `fn op panic (const self) -> string` (PANIC.md §1.5): an error type's
// optional message, a new operator spelled like every other `op`. It
// parses in a type's body and in an extension, prints back as written,
// and takes no operand besides the receiver. Its full signature rule
// (`const self`, `-> string`) is P3's; here it only has to be an
// operator the arity table knows. Before it parsed, `panic` after `op`
// was "given operator is not valid to overload" (S045E).

class ConfigError {
    var key: string
    fn op panic (const self) -> string { return "missing config key" }
}

struct Plain { var n: i32 }

extend Plain {
    fn op panic (const self) -> string { return "plain" }
}

class TooMany {
    var n: i32
    fn op panic (const self, extra: i32) -> string { return "x" }
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      op_panic.k:22:5: error [SC055E]: 'op panic' takes no operand besides the receiver, not 1
// DIAG-NOT:  error [
//
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE:      FunctionDecl  op panic (const self) -> string
// TREE:      FunctionDecl  op panic (const self) -> string
// TREE:      FunctionDecl  op panic (const self, extra: i32) -> string
