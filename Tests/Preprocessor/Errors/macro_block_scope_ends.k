// A block's macro ends with the block: a use after it, and one in a
// sibling block, name no macro. A block may not redefine a macro of an
// enclosing block or of the file's own scope.
macro top!() { 1 }

fn first() -> i32 {
    macro local!() { 2 }
    {
        macro inner!() { 3 }
    }

    return inner!()
}

fn second() -> i32 {
    return local!()
}

fn third() -> i32 {
    macro local!() { 4 }
    if true {
        macro local!() { 5 }
    }

    macro top!() { 6 }
    return local!()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: macro_block_scope_ends.k:12:12: error [R013E]: unknown macro 'inner!'
// CHECK: macro_block_scope_ends.k:16:12: error [R013E]: unknown macro 'local!'
// CHECK: macro_block_scope_ends.k:22:15: error [S040E]: duplicate macro 'local!' in this scope
// CHECK: macro_block_scope_ends.k:25:11: error [S040E]: duplicate macro 'top!' in this scope
// CHECK-NOT: error
