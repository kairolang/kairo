// A named initializer split over lines, last field with no trailing
// comma. The field list did not suppress newlines, so the newline before `}`
// ended the list: S054E "expected '}' to close named initializer". The
// one-line form and a trailing comma parsed (structures.mdx:
// `Point { x: 1.0, y: 2.0 }`). Sites: Memory/ArenaList.k,
// Support/FileIO/VirtualFileManager.k, Lexer/BalanceTracker.k.

struct Chunk {
    var base: i32
    var count: i32
}

fn make(n: i32) -> i32 {
    var c = Chunk {
        base:  1,
        count: 0
    }
    var d = Chunk {
        base: (n)
            - 1,
        count: c.count
    }
    return c.base + d.base
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)
