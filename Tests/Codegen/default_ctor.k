// Default construction runs: `Foo()` and `var f: Foo` on a class whose
// only constructor is `= default`, a nullary one with a body, one whose
// every argument defaults; numbers and pointers zero; an array of records
// builds each element. `var e: Opt` (defaults only through arguments)
// is SC116E for now, so it is written `Opt()` here. (A brace initializer on a class with a constructor
// ICEd in EmitIR; Sema now rejects it -- Tests/Sema/Check/default_init.k.)

class Def {
    pub var a: i32 = 3
    fn Def(self) = default
}
class Body {
    pub var a: i32
    fn Body(self) { self.a = 5 }
}
class Opt {
    pub var a: i32
    fn Opt(self, a: i32 = 7) { self.a = a }
}

fn main() -> i32 {
    var a = Def()
    var b: Def
    var c: Body
    var d = Body()
    var e = Opt()
    var f: i64
    var g: *i32
    var h: [Body; 2]
    if (a.a != 3) || (b.a != 3) { return 1 }
    if (c.a != 5) || (d.a != 5) { return 2 }
    if e.a != 7 { return 3 }
    if f != 0 { return 4 }
    if g != &null { return 5 }
    if (h[0].a != 5) || (h[1].a != 5) { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
