// A generic base with virtual methods: a class deriving a fixed instance
// (`derives Source<i32>`) overrides it, a `*Counter` upcasts to
// `*Source<i32>`, and a generic function deduces T from that pointer and
// dispatches through it.
//
// Two neighbours do not work yet and live in their own XFAIL files: a
// GENERIC derived class's instance does not upcast to its base instance
// (generic_instance_upcast.k), and `pull<i32>(&n)` with explicit arguments
// does not convert the derived pointer (generic_explicit_upcast.k).

class <T> Source {
    virtual fn get(self) -> i32 { return 0 }
}

class Counter derives Source<i32> {
    var n: i32
    fn Counter(self) { self.n = 0 }
    override fn get(self) -> i32 { self.n += 1  return self.n }
}

fn <T> pull(s: *Source<T>) -> i32 { return s->get() }

fn main() -> i32 {
    var r = 0
    var n = Counter()
    var sn: *Source<i32> = &n
    if pull(sn) == 1 { r += 1 }
    if pull(sn) == 2 { r += 2 }
    if sn->get() == 3 { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
