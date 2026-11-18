// A macro an `ffi` block defines inside a function ends with the function,
// not with the block, and one redefined after an `ffi` block in the same
// scope is a duplicate. Every other brace still scopes a macro.
fn first() -> i32 {
    ffi "c" {
        macro in_first!() { 1 }
    }

    return in_first!()
}

fn second() -> i32 {
    return in_first!()
}

ffi "c" {
    macro twice!() { 1 }
}

macro twice!() { 2 }

fn third() -> i32 {
    {
        macro plain!() { 3 }
    }

    return plain!()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: macro_ffi_block_scope.k:13:12: error [R013E]: unknown macro 'in_first!'
// CHECK: macro_ffi_block_scope.k:20:7: error [S040E]: duplicate macro 'twice!' in this scope
// CHECK: macro_ffi_block_scope.k:27:12: error [R013E]: unknown macro 'plain!'
// CHECK-NOT: error
