// P331: `measure`'s and `Bag::add`'s string parameters are never mutated,
// so the header declares them `const ::builtin::string::string &`; the
// definition in words.o says the same. `grow`'s is mutated: by value.

pub fn make(n: usize) -> string {
    var s = string()
    for var i: usize = 0; i < n; ++i { s.push_back(97) }
    return s
}

pub fn measure(s: string) -> usize { return s.length() }

pub fn grow(s: string) -> usize { s.push_back(33); return s.length() }

pub class Bag {
    pub var total: usize = 0
    pub fn Bag(self) { }
    pub fn add(self, s: string) { self.total += s.length() }
}
