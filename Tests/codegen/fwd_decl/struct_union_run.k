// A bodiless `struct` / `union` outside `ffi` is a forward declaration
// (structures.mdx, unions.mdx "Forward Declarations"), merged with its
// definition wherever that sits in the scope: before the definition, after
// it, twice, generic, inside a module block. Every shape is named through a
// pointer before the definition is reached, then built and read, so the
// C++ has to forward-declare each with its own tag (`struct` / `union`).

struct Node                     // forward declaration, then used by pointer
struct Tree {
    var root: unsafe *Node
    var size: i32
}
struct Node {
    var value: i32
    var left: unsafe *Node
    var right: unsafe *Node
}

union Bits { var i: i64  var b: [u8; 8] }
union Bits                      // after the definition: the same entity

struct Twice
struct Twice                    // two forward declarations: still one
struct Holder { var t: unsafe *Twice }
struct Twice { var n: i32 }

struct <T> Link                 // a generic one
struct <T> Chain { var first: unsafe *Link<T> }
struct <T> Link { var v: T  var next: unsafe *Link<T> }

module m {
    union Word
    struct Cell { var w: unsafe *Word }
    union Word { var u: u32  var s: i32 }
}

fn main() -> i32 {
    var leaf = Node{value: 5, left: &null, right: &null}
    var t = Tree{root: unsafe &leaf, size: 1}
    var bits = Bits{i: 2}
    var tw = Twice{n: 3}
    var h = Holder{t: unsafe &tw}
    var l = Link<i32>{v: 4, next: &null}
    var c = Chain<i32>{first: unsafe &l}
    var w = m::Word{s: 6}
    var cell = m::Cell{w: unsafe &w}
    unsafe {
        // 5 + 1 + 2 + 3 + 4 + 6
        return t.root->value + t.size + (bits.i as i32) + h.t->n + c.first->v + cell.w->s
    }
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 21
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
