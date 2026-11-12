// Corpus for Sema/ExprTyper/const_self_field.k: writes through the const
// `self` of a `const self` method.
class Rec {
    pub var y: i32 = 0
    pub var v: [i32] = [1, 2]
    pub mutable var hits: i32 = 0
    pub fn Rec(self) { }

    pub fn set_y(const self) { self.y = 10 }
    pub fn bump_y(const self) { self.y += 1 }
    pub fn set_elem(const self) { self.v[0] = 1 }
    pub fn read(const self) -> i32 { return self.y + self.v[0] }
    pub fn count(const self) { self.hits = 10 }
}

fn main() -> i32 { return 0 }
