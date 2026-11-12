// Uses of a split subscript whose rule is not yet specified
// get the most conservative behaviour, an error, rather than a guessed rule.
// Each is an open design question.
//
//   - Row 36: an element's binary operator declared on plain `self`
//     (`vs[0] + 2` with `op + (self, ...)`). The design leans to "any
//     non-const receiver makes the use a place" but leaves it open (Q11);
//     here the use is a read, the element is `const V`, and the operator is
//     the ordinary "not const" error. A `const self` operator reads fine.
//   - Row 37 is not one of them: `for e in ss[0]` over an element whose
//     `op in` takes `self` follows the receiver rule (the place form; see
//     Codegen/operators/subscript_split_receivers.k), and is no error.
//   - Reads the design calls plain reads stay reads: a `match` scrutinee and
//     an f-string hole (rows 46, 7).

class V {
    var x: i32
    fn V(self) { self.x = 1 }
    fn op + (self, o: i32) -> i32 { return self.x + o }
    fn op - (const self, o: i32) -> i32 { return self.x - o }
}

class Seq {
    var d: [i32; 2]
    fn Seq(self) { self.d = [1, 2] }
    fn op in (self) -> yield i32 {
        for x in self.d {
            yield x
        }
    }
}

class Vs {
    var r: [V; 2]
    var w: [V; 2]
    fn Vs(self) { }
    fn op [] (const self, i: usize) -> *const V { return &self.r[i] }
    fn op []= (self, i: usize) -> *V { return &self.w[i] }
}

class Seqs {
    var r: [Seq; 1]
    var w: [Seq; 1]
    fn Seqs(self) { }
    fn op [] (const self, i: usize) -> *const Seq { return &self.r[i] }
    fn op []= (self, i: usize) -> *Seq { return &self.w[i] }
}

fn main() -> i32 {
    var vs = Vs()
    var s = vs[0] + 2
    var m = vs[0] - 2
    var q = 0
    match vs[1].x {
        case 1 { q += 1 }
        default { q += 2 }
    }

    var t = f"{vs[0].x}"
    var ss = Seqs()
    for e in ss[0] {
        q += e
    }

    return s + m + q
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag
// RUN: %FileCheck %s < %t.diag
// CHECK-DAG: subscript_split_open_rows.k:51:13: error [SC063E]: no matching overload for call to 'op +'
// CHECK-DAG: note [I900N]: candidate not viable: 'op +' is not const; it cannot be called on a const object
// CHECK-NOT: subscript_split_open_rows.k:52:
// CHECK-NOT: subscript_split_open_rows.k:54:
// CHECK-NOT: subscript_split_open_rows.k:59:
// CHECK-NOT: subscript_split_open_rows.k:61:
