// The type, its const element specialization and its extensions, as a
// library file declares them. Imported by main.k.

pub class <T> View {
    pub var p: *T
    pub var n: usize
    pub fn View(self, p: *T, n: usize) { self.p = p; self.n = n }
    pub fn set0(self, v: T) { *self.p = v }
}

pub class <T> View<const T> {
    pub var p: *const T
    pub var n: usize
    pub fn View(self, p: *const T, n: usize) { self.p = p; self.n = n }
}

extend <T> View<T> {
    pub fn size(const self) -> usize { return self.n }
    pub fn first(const self) -> *const T { return self.p }
    pub fn both(const self) -> usize { return self.size() + self.size() }
}

pub interface Same {
    fn same(const self, const o: Self) -> bool
}

extend <T impl Same> View<T> {
    pub fn has(const self, const v: T) -> bool { return (*self.p).same(v) }
    pub fn op == (const self, const o: View<const T>) -> bool { return (*self.p).same(*o.p) }
}

pub fn <U> measure(v: View<const U>) -> usize { return v.both() }
pub fn <U impl Same> alike(a: View<const U>, b: View<const U>) -> bool { return a == b }
