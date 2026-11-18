// Members a macro body declares, beside its operators. Two
// defects, both silent until a use:
//   - a primitive keyword from a macro body (`-> i32`, `o: i32`) arrived
//     as TkMacroExpand, and TypeResolve keys `i32` by token KIND, so the
//     return type stayed unresolved: `n.get()` was `<unknown>`, and a
//     parameter of primitive type made the call SC063E "parameter type is
//     invalid". NamedIdentExpr::create unwraps a keyword.
//   - codegen read a declared name's imm without looking through the
//     expansion, where the imm is the expansion record: `fn get(o: i32)`
//     from `mm!()` was emitted as `mm(signed int main)`, so the member was
//     missing and `o` undeclared (CXXSpell::tok_name).
// A free function from a macro already ran, because its declaration and
// its calls were misspelled the same way; it is here so it stays right.

macro members!() {
    fn get(const self, o: i32) -> i32 { return o + self.v }
    fn flag(const self) -> bool { return self.v > 2 }
    static fn make(v: i32) -> Self { return Self(v) }
}

macro free_fn!() { fn helper(q: i32) -> i32 { return q + 1 } }

class Num {
    var v: i32
    fn Num(self, v: i32) { self.v = v }
    members!()
}

free_fn!()

fn main() -> i32 {
    var n = Num::make(3)
    var g: i32 = n.get(4)
    if g != 7 { return 1 }
    if !n.flag() { return 2 }
    if helper(41) != 42 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
