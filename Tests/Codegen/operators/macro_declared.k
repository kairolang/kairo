// Operators declared through a macro. A macro-expanded token
// is TkMacroExpand until unwrapped, and the operator's identity was read
// off that raw kind: every operator one macro declared keyed as the same
// table cell (R041E "class member 'op <' cannot be redeclared" between
// `op <`, `op ==` and `op +`), and `op []` / `op []=` / `op ()` from a
// macro body were S045E "given operator is not valid to overload". A
// declaration stores its operator tokens unwrapped
// (DeclParse::_stored_op_token), so each one is its own operator,
// selected and RUN as such: every check returns its own number.

macro bin!(t, r) { fn op t (const self, o: Self) -> i32 { return r + o.v } }
macro cmp!(t, r) { fn op t (const self, o: Self) -> bool { return r } }
macro post!(t) { fn op t (self) -> i32 { var o = self.v; self.v += 10; return o } }

class Num {
    var v: i32
    fn Num(self, v: i32) { self.v = v }

    bin!(+, 100)
    bin!(-, 200)
    bin!(*, 300)
    cmp!(<, true)
    cmp!(==, false)
    // the l/r marker and `++` both come from the argument
    post!(r++)
    fn op % (const self, o: Self) -> i32 { return 4 }
}

// Every place and call operator spelled inside a macro body.
macro subscripts!() {
    fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

macro call_op!() {
    fn op () (const self, x: i32) -> i32 { return x * 2 }
}

class Two {
    var r: [i32; 2]
    var w: [i32; 2]
    fn Two(self) {
        self.r = [5, 6]
        self.w = [0, 0]
    }

    subscripts!()
    call_op!()
}

fn main() -> i32 {
    var a = Num(1)
    var b = Num(2)
    if a + b != 102 { return 1 }
    if a - b != 202 { return 2 }
    if a * b != 302 { return 3 }
    if !(a < b) { return 4 }
    if a == b { return 5 }
    if a % b != 4 { return 6 }
    if a++ != 1 || a.v != 11 { return 7 }

    var t = Two()
    if t[1] != 6 { return 8 }       // the read form
    t[1] = 9                        // the place form
    if t.w[1] != 9 || t.r[1] != 6 { return 9 }
    if t(21) != 42 { return 10 }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
