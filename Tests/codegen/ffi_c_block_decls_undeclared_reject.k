// Members of an `ffi "c" { ... }` block are declared with their written
// signatures: a function the block does not list is undeclared, and a call
// that does not match a listed signature is rejected by Kairo rather than
// reaching codegen or the C compiler.

ffi "c" {
    fn abs(x: i32) -> i32
}

fn main() -> i32 {
    var a = labs(-4)
    var b = abs(1, 2)
    var c: string = abs(3)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E"
// CHECK: ffi_c_block_decls_undeclared_reject.k:11:13: error [R020E]: use of undeclared identifier 'labs'
// CHECK: ffi_c_block_decls_undeclared_reject.k:12:13: error [SC063E]: no matching overload for call to 'abs'
// CHECK: ffi_c_block_decls_undeclared_reject.k:7:5: note [I900N]: candidate not viable: expects 1 argument(s), 2 given
// CHECK: ffi_c_block_decls_undeclared_reject.k:13:21: error [SC028E]: cannot convert 'i32' to 'string'
