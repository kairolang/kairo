// --emit-ast-bin=<path> writes the entry file's parsed AST in the format of
// Compiler/Spec/Serialization.md. The format stores nothing of the process
// or the machine (no pointers, fids, global offsets or absolute paths), so
// the same source gives the same bytes every time and from any directory;
// that is what the three `cmp`s hold it to. --verify-ast-roundtrip reloads
// the tree beside the parsed one and reports a difference as I002F, and
// --print-stats says what was written.

struct Point {
    var x: i32
    var y: i32
}

fn add(a: i32, b: i32) -> i32 {
    return a + b
}

fn main() -> i32 {
    var p = Point { x: 1, y: 2 }
    var total = add(p.x, p.y)
    for var i: i32 = 0; i < 3; ++i {
        total += i
    }

    return total - 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d/elsewhere && cp %s %t.d/elsewhere/moved.k
// RUN: %kairo %s --syntax-only --emit-ast-bin=%t.a
// RUN: %kairo %s --syntax-only --emit-ast-bin=%t.b
// RUN: cmp %t.a %t.b
// RUN: cd %t.d/elsewhere && %kairo moved.k --syntax-only --emit-ast-bin=%t.c
// RUN: cmp %t.a %t.c
// RUN: %kairo %s --type-check-only --emit-ast-bin=%t.e
// RUN: cmp %t.a %t.e
//
// The file starts with the magic and format version 1.
// RUN: head -c 8 %t.a | od -An -c | %FileCheck %s --check-prefix=MAGIC
// MAGIC: K   A   S   T 001  \0  \0  \0
//
// Nothing of where it was written from is in it.
// RUN: not grep -a -c -e "%/S" -e "%/t.d" %t.a
//
// RUN: %kairo %s --type-check-only --verify-ast-roundtrip --print-stats | %FileCheck %s --check-prefix=STATS
// STATS: [stats] ast-serialize: {{[0-9]+}} files, {{[0-9]+}} bytes for {{[0-9]+}} source bytes, {{[0-9]+}} nodes
//
// Without a flag there is no such line and no ASTSerialize time region.
// (`env -u`: this suite can itself be run with the variable set, through
// Scripts/lit_ast_roundtrip.py, and these two runs are the ones that must
// not round-trip.)
// RUN: env -u KAIRO_AST_ROUNDTRIP %kairo %s --type-check-only --print-stats --time-passes | %FileCheck %s --check-prefix=OFF --allow-empty
// OFF-NOT: ast-serialize
// OFF-NOT: ASTSerialize
//
// The environment switch is --ast-roundtrip: the tree Sema sees, and the
// dumps print, is the reloaded one.
// RUN: %kairo %s --syntax-only --print-ast=tree > %t.parsed
// RUN: %kairo %s --syntax-only --print-ast=tree --ast-roundtrip > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: env KAIRO_AST_ROUNDTRIP=1 %kairo %s --type-check-only --print-stats --print-symbols > %t.env
// RUN: %FileCheck %s --check-prefix=ENV < %t.env
// ENV: [stats] ast-serialize:
// ENV: scope <tu>
// RUN: env -u KAIRO_AST_ROUNDTRIP %kairo %s --type-check-only --print-symbols > %t.syms
// RUN: grep -v "ast-serialize" %t.env | diff %t.syms -
