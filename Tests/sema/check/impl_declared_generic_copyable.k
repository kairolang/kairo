// A generic conformer declaring `impl Copyable` with no `copy` of its own
// holds at the declaration: every COPY instance meets the Copyable lang
// item's `copy` through its copy constructor, and whether an instance is
// COPY depends on its type argument, so the clause reports nothing and
// each instance is checked where a bound meets it. Covers a generic class
// and a generic struct through `extend <T> G<T> impl Copyable`.

class <T> Box impl Copyable {
    pub var v: T
}

struct <T> G {
    pub var v: T
}

extend <T> G<T> impl Copyable { }

fn <P impl Copyable> dup(p: P) -> P { return p.copy() }

fn main() -> i32 {
    return dup(Box<i32>{v: 1}).v + dup(G<i32>{v: 2}).v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: error
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 3
