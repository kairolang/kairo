// Imported by copy_generic_bodies.k: `.copy()` on concrete COPY types
// inside generic code of another file.

pub struct Pt {
    pub var x: i32
}

pub class <T> Tagged {
    pub var v: T
    pub var n: i32

    pub fn Tagged(self, v: T) {
        self.v = v
        self.n = 7
    }

    pub fn count(const self) -> i32 {
        return self.n.copy()
    }
}

pub fn <T> seven(const x: T) -> i32 {
    var p = Pt { x: 3 }
    var q = p.copy()
    return 4.copy() + q.x
}
