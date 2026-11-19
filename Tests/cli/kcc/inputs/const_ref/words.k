// `measure`'s and `Bag::add`'s string parameters are never mutated,
// so the header declares them `const ::builtin::string::string &`; the
// definition in words.o says the same. `grow`'s is mutated: by value.

pub fn make(n: usize) -> string {
    var s = string()
    for var i: usize = 0; i < n; ++i { s.push('a') }
    return s
}

pub fn measure(s: string) -> usize { return s.size() }

pub fn grow(s: string) -> usize { s.push('!'); return s.size() }

pub class Bag {
    pub var total: usize = 0
    pub fn Bag(self) { }
    pub fn add(self, s: string) { self.total += s.size() }
}
