// An array field with no default can be built element by element in its
// constructor: `self.f[k] = e` for every k in 0..N-1, each once with a
// constant index, before `f` (or `self`) is read (CtorInitCheck). Each
// write constructs its element in place in f's slot, where it is written
// (`init_at`), so the elements are evaluated in source order, interleaved
// with the statements around them; the mem-initializer moves them into the
// member as it does for a whole write (CODEGEN.md §6).
//
// Probe owns one malloc'd i32, moves only, and counts: `live` (built, not
// destroyed), `moves`. A leak or a double destroy shows as `live` != 0, an
// element built twice or never as a wrong value; valgrind (memcheck) runs
// the same binary clean.
ffi "c" import "stdlib.h"

var live: i32 = 0
var moves: i32 = 0
var trace: i64 = 0

fn mark(d: i64) { trace = trace * 10 + d }

class Probe {
    var p: unsafe *i32
    pub fn Probe(self, v: i32) {
        unsafe { self.p = malloc(4) as unsafe *i32 }
        (*self.p) = v
        live += 1
    }
    @move
    fn Probe(self, other: Self) {
        self.p = other.p
        unsafe { other.p = &null }
        live += 1
        moves += 1
    }
    fn op delete(self) {
        if self.p != &null { unsafe { free(self.p as unsafe *void) } }
        live -= 1
    }
    pub fn get(const self) -> i32 { return *self.p }
}

fn make(v: i32) -> Probe {
    mark(v)
    return Probe(v)
}

class Rack {
    pub var slots: [Probe; 3]
    pub var flag: bool
    pub var tag: i32 = 0

    // Out of order, with statements between the writes: they run where
    // written (trace 3, 9, 1, 2, 6 -- the 9 between two element writes).
    fn Rack(self, a: i32) {
        self.slots[2] = make(a + 2)
        mark(9)
        self.slots[0] = make(a)
        self.flag = a > 0
        self.slots[1] = make(a + 1)
        self.tag = self.slots[1].get()       // f is whole here: an ordinary read
        self.slots[0] = make(a + 5)          // and an ordinary element assignment
    }

    // Both branches build every element.
    fn Rack(self, a: i32, flip: bool) {
        if flip {
            self.slots[0] = Probe(a)
            self.slots[1] = Probe(a)
            self.slots[2] = Probe(a)
        } else {
            self.slots[2] = Probe(a + 1)
            self.slots[1] = Probe(a + 1)
            self.slots[0] = Probe(a + 1)
        }
        self.flag = flip
    }

    fn sum(self) -> i32 { return self.slots[0].get() + self.slots[1].get() + self.slots[2].get() }
}

fn check() -> i32 {
    {
        trace = 0
        moves = 0
        var r = Rack(1)
        if trace != 39126 { return 1 }
        // 6 + 2 + 3; tag 2.
        if (r.sum() != 11) || (r.tag != 2) || (!r.flag) { return 2 }
        // Three elements built, each moved into its slot element and from
        // there into the member: 6. Then make(6) assigned into slot 0: 1.
        if moves != 7 { return 3 }
        if live != 3 { return 4 }
    }
    if live != 0 { return 5 }
    {
        var t = Rack(4, true)
        var f = Rack(4, false)
        if (t.sum() != 12) || (f.sum() != 15) || (!t.flag) || f.flag { return 6 }
        if live != 6 { return 7 }
    }
    if live != 0 { return 8 }
    return 0
}

fn main() -> i32 { return check() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Each initializing write builds its element in the slot, in place; the
// element write after the last one is an ordinary assignment, in the built
// object (the constructor's split falls where the array is whole).
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}ctor_field_elems.k
// IR:      struct __kairo_slot<T[N]>
// IR:      __kairo_s{{ ?}}.{{ ?}}slots{{ ?}}.{{ ?}}init_at{{ ?}}({{ ?}}2{{ ?}},
// IR:      __kairo_s{{ ?}}.{{ ?}}slots{{ ?}}.{{ ?}}init_at{{ ?}}({{ ?}}0{{ ?}},
// IR:      __kairo_s{{ ?}}.{{ ?}}slots{{ ?}}.{{ ?}}init_at{{ ?}}({{ ?}}1{{ ?}},
// IR:      slots{{ ?}}{
// IR-NEXT: __kairo_s{{ ?}}.{{ ?}}slots{{ ?}}.{{ ?}}take{{ ?}}({{ ?}}){{\[}}0{{\]}}{{ ?}},{{.*}}take{{ ?}}({{ ?}}){{\[}}2{{\]}}
// IR:      this{{ ?}}->{{ ?}}slots{{\[}}0{{\]}}{{ ?}}={{ ?}}

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
