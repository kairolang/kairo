import std::io::println

pub struct <A, B> Combined {
    pub var first:  A
    pub var second: B
}

pub class <T> Box {
    pub var val: T

    pub fn Box(self, val: T) {
        self.val = val
    }

    pub fn <U> combine(self, other: U) -> Combined<T, U> {
        return Combined<T, U>{first: self.val, second: other}
    }

    fn op delete(self) {
        println("Box::~Box()")
    }
}

