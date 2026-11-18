// `var t = a[i..j]` on a mutable `a` whose type declares `op []=`
// binds the place form, so `t` is a view that may be written through, and a
// `const` binding takes the read form. When nothing in the scope writes
// through `t` the place form was not needed: SC281W, with the fix-it that
// declares it `const`.
//
//   - `a` is only read (`a[0]`, `a[1]`): warned.
//   - `b[0] = 4` writes through it, `&e[1]` may: not warned.
//   - `c` is passed on to a function: not a known read, so not warned.
//   - `d` is `const` (the read form): not warned.
//   - `f` is a range of an array (Slice's own `op []`, no `op []=`): not
//     warned.
//   - `h` reads a field of the view: not a known read, so not warned.

class View {
    var d: [i32; 4]
    var e: [i32; 4]
    fn View(self) {
        self.d = [1, 2, 3, 4]
        self.e = [5, 6, 7, 8]
    }

    fn op [] (self, r: Range<usize>) -> [i32;] { return self.e[r.begin..r.end] }
    fn op []= (self, r: Range<usize>) -> [i32;] { return self.d[r.begin..r.end] }
}

fn sink(s: [i32;]) -> i32 { return s[0] }

fn main() -> i32 {
    var v = View()
    var a = v[0..2]
    var x = a[0] + a[1]
    var b = v[1..3]
    b[0] = 4
    var c = v[2..4]
    var y = sink(c)
    const d = v[0..1]
    var e = v[0..2]
    var *p = &e[1]
    var arr: [i32; 3] = [1, 2, 3]
    var f = arr[0..2]
    var z = f[0]
    var h = v[0..3]
    var n = h.len
    return x + y + z + d[0] + *p + (n as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag
// RUN: %FileCheck %s --check-prefix=DIAG < %t.diag
// DIAG:      subscript_split_range_binding.k:31:9: warning [SC281W]: 'a' binds the place form ('op []=') of its sub-range but is never written through; declare it 'const' to bind the read form
// DIAG-NEXT: fix-it:{{.*}}:{31:5-31:8}:"const"
// DIAG-NOT:  {{warning|error}}
