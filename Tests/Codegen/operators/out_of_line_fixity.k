// Marked `++` / `--` declared in the type and defined out of line: each
// definition is the body of its own declaration, so the program links and
// prefix and postfix run their own bodies.

struct C {
    var x: i32
    fn op l++(self) -> C
    fn op r++(self) -> C
    fn op l--(self) -> C
    fn op r--(self) -> C
}

fn C::op l++(self) -> C { return C{ x: self.x + 1 } }
fn C::op r++(self) -> C { return C{ x: self.x + 20 } }
fn C::op l--(self) -> C { return C{ x: self.x + 300 } }
fn C::op r--(self) -> C { return C{ x: self.x + 4000 } }

fn main() -> i32 {
    var c = C{ x: 0 }
    var a = ++c
    var b = c++
    var d = --c
    var e = c--
    if a.x != 1 || b.x != 20 || d.x != 300 || e.x != 4000 {
        return 1
    }

    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
