// A forward declaration in one `module m { }` block and its definition in
// another block of the same module, in one file. The blocks are one scope
// ("as if one block", IMPORTS.md), so the two declarations are one entity;
// each block keeps its own table, and they were never linked, so every use
// of the name was R028E "'Payload' is ambiguous". Every record keyword, and
// a nested module whose own blocks sit in two blocks of the outer one.

module m {
    union Payload
    struct Msg { var p: unsafe *Payload }
    class Box
}

module m {
    union Payload { var i: i32  var f: f32 }
    class Box { var n: i32 }
    struct Late
    module inner { struct Deep }
}

module m {
    struct Late { var v: i32 }
    module inner { struct Deep { var d: i32 } }
}

fn main() -> i32 {
    var p = m::Payload{i: 4}
    var msg = m::Msg{p: unsafe &p}
    var b = m::Box{n: 5}
    var l = m::Late{v: 6}
    var d = m::inner::Deep{d: 7}
    unsafe {
        // 4 + 5 + 6 + 7
        return msg.p->i + b.n + l.v + d.d
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
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 22
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
