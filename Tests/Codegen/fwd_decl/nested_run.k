// A record forward-declared INSIDE a class body (`struct Cell;`, the
// shape Compiler/Threading/PartitionQueue.k uses) and defined later in the
// same body. The class emits the nested record once: the forward
// declaration and its definition are one entity, and a second emitted body
// was clang's "redefinition of 'Cell'". A nested forward declaration that
// is never defined is emitted as a declaration only, and is fine behind a
// pointer. Classes nest the same way.

class Queue {
    struct Cell;
    pub var head: unsafe *Self::Cell = &null
    pub var slots: [Self::Cell; 2]
    struct Cell {
        pub var seq: u64 = 0
        pub var v: i32 = 0
    }
}

class Pool {
    class Block
    union Opaque;                     // never defined: pointers only
    pub var first: unsafe *Self::Block = &null
    pub var raw: unsafe *Self::Opaque = &null
    class Block { pub var size: i32 = 9 }
}

fn main() -> i32 {
    var q = Queue()
    q.slots[1].v = 3
    q.head = unsafe &q.slots[1]
    var p = Pool()
    var b = Pool::Block()
    p.first = unsafe &b
    unsafe {
        if p.raw != &null { return 100 }
        return q.head->v + p.first->size        // 3 + 9
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
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 12
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
