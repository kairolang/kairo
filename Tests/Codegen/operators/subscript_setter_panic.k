// A setter form of `op []=` declared `panic`. `x[k] = v` is its call, so
// the panic is held where the assignment stands: a `try` around the store
// catches it, a `panic` function propagates it, and a store that panics
// leaves the container as it was. A store with neither is SC221E, with the
// note at the setter. Each failing check returns its number.

struct Bad {}

class Lim {
    pub var d: [i32; 4]
    fn Lim(self) { }
    fn op [] (const self, i: usize) -> i32 { return self.d[i] }
    fn op []= (self, i: usize, v: i32) panic(Bad) {
        if v < 0 { panic Bad {} }
        self.d[i] = v
    }
}

fn store(l: *Lim, v: i32) panic {
    (*l)[1] = v
}

fn main() -> i32 {
    var l = Lim()
    try { l[0] = 4 } catch e: Bad { return 1 }
    if l[0] != 4 { return 2 }
    var hit = 0
    try { l[1] = -1 } catch e: Bad { hit = 1 }
    if hit != 1 || l[1] != 0 { return 3 }
    try { store(&l, 6) } catch e: Bad { return 4 }
    hit = 0
    try { store(&l, -2) } catch e: Bad { hit = 1 }
    if hit != 1 || l[1] != 6 { return 5 }
    return 0
}

eval if defined!(UNHANDLED) {
    fn quiet(l: *Lim) {
        (*l)[1] = 3
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: { %kairo %s --type-check-only -DUNHANDLED 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: subscript_setter_panic.k:39:{{[0-9]+}}: error [SC221E]: unhandled panic: this operator may panic with 'Bad', and 'quiet' is not marked 'panic'
// DIAG: subscript_setter_panic.k:13:5: note [SC222N]: 'op []=' is declared 'panic' here
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
