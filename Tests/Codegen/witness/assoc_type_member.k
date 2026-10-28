// A member of an associated type, reached through the associated type's
// OWN bounds (interfaces.md, Associated Types; MONO.md G5.6 left it
// SC116E): with `type Item impl Display`, a body bounded `T impl Store`
// may call `x.show()` on `x: T::Item`, and `s.get().show()` on a call
// result. The call goes through the associated type's witness:
// `Display_witness<typename Store_witness<T>::Item>::show(&x)`.
//
// Two conformers with different Items (a class with the method, a struct
// that gets it from an extension), and a second interface on the Item.

interface Display {
    fn show(const self) -> i32
}

interface Weigh {
    fn weight(const self) -> i32
}

interface Store {
    type Item impl Display, Weigh
    fn get(const self) -> Self::Item
}

class Coin {
    pub var v: i32
    fn Coin(self, v: i32) { self.v = v }
    fn show(const self) -> i32 { return self.v }
    fn weight(const self) -> i32 { return 2 }
}

struct Gem {
    pub var c: i32
}
extend Gem impl Display {
    fn show(const self) -> i32 { return self.c * 10 }
}
extend Gem impl Weigh {
    fn weight(const self) -> i32 { return 3 }
}

class Purse impl Store {
    type Item = Coin
    fn Purse(self) { }
    fn get(const self) -> Coin { return Coin(4) }
}

class Box impl Store {
    type Item = Gem
    fn Box(self) { }
    fn get(const self) -> Gem { return Gem { c: 5 } }
}

fn <T impl Store> score(s: T) -> i32 {
    var x: T::Item = s.get()
    return x.show() + s.get().weight()
}

fn main() -> i32 {
    return score(Purse()) + score(Box())     // (4 + 2) + (50 + 3)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Display_witness<typename{{ ?}}::{{.*}}Store_witness<T>::Item>::show(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 59
