// Imported by main.k: a generic function declared, used, then defined in
// this module. The importer must see one function (one candidate), not
// the declaration and the definition as two overloads.

pub interface Sized { fn size(const self) -> i32 }

pub fn <T impl Sized> total(a: T, b: T) -> i32
pub fn <T impl Sized> twice(a: T) -> i32 { return total(a, a) }
pub fn <S impl Sized> total(a: S, b: S) -> i32 { return a.size() + b.size() }
