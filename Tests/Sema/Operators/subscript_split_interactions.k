// The split subscript beside rules that landed after it:
//
//   - ArrayIndexCheck (SC291E) judges builtin subscripts only: a constant
//     index past a split type's storage is the type's business (`t[9]`,
//     `t[12]`), while the fixed array `a[5]` is still SC291E.
//   - `for e in cq[0]` on a const container: the read form hands out a const
//     `Seq`, and its `op in` takes `self`, so the iteration's own-const rule
//     (StmtTyping::_iter_own_op) refuses it, SC063E "'op in' is not const".
//   - SC279E's note owns its label: in the pretty renderer the
//     underline is on the note's line, at the `op []=`, not on the error.

class Two {
    var r: [i32; 4]
    var w: [i32; 4]
    fn Two(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

class Seq {
    var d: [i32; 2]
    fn Seq(self) { self.d = [0, 0] }
    fn op in (self) -> yield i32 {
        for x in self.d {
            yield x
        }
    }
}

class Seqs {
    var r: [Seq; 1]
    var w: [Seq; 1]
    fn Seqs(self) { }
    fn op [] (const self, i: usize) -> *const Seq { return &self.r[i] }
    fn op []= (self, i: usize) -> *Seq { return &self.w[i] }
}

class OnlySet {
    var w: [i32; 2]
    fn OnlySet(self) { }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

fn main() -> i32 {
    var t = Two()
    t[9] = 1
    var x = t[12]
    var a: [i32; 2] = [1, 2]
    var y = a[5]
    const cq = Seqs()
    for e in cq[0] {
        x += e
    }

    var os = OnlySet()
    return os[0] + x + y
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag
// RUN: %FileCheck %s --check-prefix=DIAG < %t.diag
// DIAG-NOT:  subscript_split_interactions.k:46:
// DIAG-NOT:  subscript_split_interactions.k:47:
// DIAG:      subscript_split_interactions.k:49:15: error [SC291E]: index 5 is out of range for '[i32; 2]', which has 2 elements
// DIAG:      subscript_split_interactions.k:51:14: error [SC063E]: no matching overload for call to 'op in'
// DIAG-NEXT: subscript_split_interactions.k:23:5: note [I900N]: candidate not viable: 'op in' is not const; it cannot be called on a const object
// DIAG:      subscript_split_interactions.k:56:12: error [SC279E]: 'OnlySet' declares no read subscript 'op []'; 'os[0]' here is a read
// DIAG-NEXT: subscript_split_interactions.k:41:5: note [SC279N]: only the place form, 'op []=', is declared
// RUN: { %kairo --error-format=pretty --no-color --type-check-only %s 2>&1 || true; } | %FileCheck %s --check-prefix=PRETTY --strict-whitespace
// PRETTY-LABEL: error @ {{.*}}subscript_split_interactions.k:56:12
// PRETTY:      {{^}}   56 |     return os[0] + x + y{{$}}
// PRETTY-NEXT: {{^}}      |            ^^^^^{{$}}
// PRETTY:      {{^}}    note @ {{.*}}subscript_split_interactions.k:41:5{{$}}
// PRETTY:      {{^}}      41 |     fn op []= (self, i: usize) -> *i32 { return &self.w[i] }{{$}}
// PRETTY-NEXT: {{^}}         |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ only the place form, 'op []=', is declared{{$}}
