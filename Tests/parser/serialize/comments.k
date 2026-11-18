// Annotations in a serialized AST: attributes with their arguments, and,
// under --preserve-comments, the comments the parser attaches to the node
// that follows or precedes them. Every node family carries the list
// (declarations, statements, expressions, types and patterns), an
// attribute's name is a spelling in the string table, and its arguments
// are expressions like any other.

/// Doc comment on a function.
@deprecated("use better()")
fn worse(x: i32) -> i32 {
    // a line comment before a statement
    var y = x + 1 // trailing
    /* a block comment */
    return y
}

@no_inline
@cold_path
fn better(x: i32) -> i32 {
    return x + 2
}

/// A documented record.
struct Pixel {
    /// Its first field.
    var r: u8
    var g: u8 // green
}

fn main() -> i32 {
    @likely if better(1) == 3 {
        return 0
    }

    return 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --preserve-comments --verify-ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=VERIFY --allow-empty
// RUN: { %kairo %s --syntax-only --verify-ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=VERIFY --allow-empty
// VERIFY-NOT: I002F
// RUN: { %kairo %s --syntax-only --preserve-comments --print-ast=tree 2>/dev/null || true; } > %t.parsed
// RUN: { %kairo %s --syntax-only --preserve-comments --print-ast=tree --ast-roundtrip 2>/dev/null || true; } > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %FileCheck %s < %t.reloaded
// CHECK: FunctionDecl  worse(x: i32) -> i32
// CHECK: Attribute /// doc-comment
// CHECK: Attribute @deprecated("use better()")
// CHECK: Attribute @no_inline
// CHECK: Attribute @cold_path
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag.parsed
// RUN: { %kairo %s --type-check-only --ast-roundtrip 2>&1 || true; } > %t.diag.reloaded
// RUN: diff %t.diag.parsed %t.diag.reloaded
