// `measure`'s and `Bag::add`'s Text parameters are never mutated, so the
// header declares them `const ::words::Text &`; the definition in words.o
// says the same. `grow`'s is mutated: by value. Text is COPY and not
// trivially copyable (a written copy constructor), the records the
// inference applies to.

pub class Text {
    pub var n: usize = 0
    pub fn Text(self) { }
    @copy pub fn Text(self, const other: Self) { self.n = other.n }
    pub fn size(const self) -> usize { return self.n }
    pub fn push(self, c: char) { self.n += 1 }
}

pub fn make(n: usize) -> Text {
    var s = Text()
    for var i: usize = 0; i < n; ++i { s.push('a') }
    return s
}

pub fn measure(s: Text) -> usize { return s.size() }

pub fn grow(s: Text) -> usize { s.push('!'); return s.size() }

pub class Bag {
    pub var total: usize = 0
    pub fn Bag(self) { }
    pub fn add(self, s: Text) { self.total += s.size() }
}
