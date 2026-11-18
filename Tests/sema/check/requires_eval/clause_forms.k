// A function's or a type's `requires` clause is decided by Kairo for the
// arguments it is used with: `T impl I` and `T derives B` as truth values,
// `!`, `&&`, `||`, parentheses, and comparisons over `sizeof`. A clause that
// is false is SC300E at the use, with a note on the false part saying why;
// one that holds is silent.

interface Named {
    fn name(const self) -> string
}

class Base {
    pub var k: i32
}

class Dog derives Base {
    pub fn name(const self) -> string {
        return "rex"
    }
}

class Rock {
    pub var w: i32
}

fn <T> anon(const x: T) -> i32 requires !(T impl Named) {
    return 0
}

fn <T> either(const x: T) -> i32 requires (T impl Named) || sizeof T == 1 {
    return 1
}

fn <T> both(const x: T) -> i32 requires !((T impl Named) && (T derives Base)) {
    return 2
}

fn <T> based(const x: T) -> i32 requires (T derives Base) || sizeof T == 2 {
    return 3
}

fn <T> small(const x: T) -> i32 requires (sizeof T <= 4) {
    return 4
}

struct <T> Unnamed requires !(T impl Named) { var v: T }

fn holds() -> i32 {
    var r = Rock()
    var d = Dog()
    var u = Unnamed<i32> { v: 1 }
    return anon(r) + anon(5) + either(d) + either(7 as u8) + both(r) + based(d) + small(
        3,
    )
}

fn fails() -> i32 {
    var r = Rock()
    var d = Dog()
    var u = Unnamed<Dog> { v: Dog() }
    return anon(d) + either(9 as i64) + both(d) + based(5) + small(3 as i64)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: clause_forms.k:59:13: error [SC300E]: 'Unnamed<Dog>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: clause_forms.k:45:29: note [SC300N]: 'Dog' implements 'Named'
// CHECK-NEXT: clause_forms.k:60:12: error [SC300E]: 'anon<Dog>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: clause_forms.k:25:41: note [SC300N]: 'Dog' implements 'Named'
// CHECK-NEXT: clause_forms.k:60:22: error [SC300E]: 'either<i64>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: clause_forms.k:29:44: note [SC300N]: 'i64' does not implement 'Named': it has no 'name', and this is false for T = i64
// CHECK-NEXT: clause_forms.k:60:41: error [SC300E]: 'both<Dog>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: clause_forms.k:33:41: note [SC300N]: 'Dog' implements 'Named' and 'Dog' derives 'Base'
// CHECK-NEXT: clause_forms.k:60:51: error [SC300E]: 'based<i32>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: clause_forms.k:37:43: note [SC300N]: 'i32' does not derive 'Base', and this is false for T = i32
// CHECK-NEXT: clause_forms.k:60:62: error [SC300E]: 'small<i64>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: clause_forms.k:41:43: note [SC300N]: this is false for T = i64
// CHECK-NOT: error
