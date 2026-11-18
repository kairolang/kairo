// `inline "c++"` (and `inline "c"`, and any language but "asm") is not part
// of Kairo (c-cpp.mdx, c-cpp-calling.mdx): C and C++ code comes in through
// `ffi "c++" import`. Each such block is one S095E wherever it stands, at
// file scope, in a module, type or function body, and parsing goes on after
// it. `inline "asm"` is a statement, so where a member or declaration
// belongs it is S048E.

inline "c++" {
    static int helper_one() { return 4; }
}

module m {
    inline "c" { int z; }
    pub fn f() -> i32 { return 1 }
}

class C {
    pub var v: i32 = 1
    inline "c++" {
        int extra() { return 5; }
    }
}

fn g() -> i32 {
    inline "cuda" { }
    return 2
}

// Parsing goes on after each block: this is still read and checked.
fn main() -> i32 {
    inline "c++" { int q = 3; (void)q; }
    return m::f() + g() + C().v
}

// A visibility group in a type body reads its inline blocks the same way.
class D {
    inline "asm" { "nop" }
    pub {
        inline "c++" { int x; }
    }
}

module n {
    inline "asm" { "nop" }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s
// CHECK:      inline_foreign_block_rejected.k:8:1: error [S095E]: 'inline "c++"' is not part of Kairo: declare the code in a header and import it with 'ffi "c++" import'
// CHECK-NEXT: inline_foreign_block_rejected.k:13:5: error [S095E]: 'inline "c"' is not part of Kairo: declare the code in a header and import it with 'ffi "c" import'
// CHECK-NEXT: inline_foreign_block_rejected.k:19:5: error [S095E]: 'inline "c++"' is not part of Kairo
// CHECK-NEXT: inline_foreign_block_rejected.k:25:5: error [S095E]: this inline foreign block's language is not part of Kairo; only 'inline "asm"' is
// CHECK-NEXT: inline_foreign_block_rejected.k:31:5: error [S095E]: 'inline "c++"' is not part of Kairo
// CHECK-NEXT: inline_foreign_block_rejected.k:37:5: error [S048E]: an 'inline "asm"' block is a statement, not a member of a type body; put it in a function body
// CHECK-NEXT: inline_foreign_block_rejected.k:39:9: error [S095E]: 'inline "c++"' is not part of Kairo
// CHECK-NEXT: inline_foreign_block_rejected.k:44:5: error [S048E]: an 'inline "asm"' block is a statement, not a member of a module body; put it in a function body
// CHECK-NOT:  error
// RUN: %kairo --explain S095E | %FileCheck %s --check-prefix=EXPLAIN
// EXPLAIN: inline foreign block in a language Kairo does not embed
