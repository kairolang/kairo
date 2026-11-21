// b.k: see a.k.
import self::a::*

pub class Banana {
    pub var n: i32

    pub fn Banana(self, n: i32) {
        self.n = n
    }

    pub fn peel(self) -> i32 {
        return self.n * 2
    }
}

pub class Basket {
    pub var a: Apple

    pub fn Basket(self, k: i32) {
        self.a = Apple(k)
    }
}

pub fn <T> banana_of(const t: T, k: i32) -> Banana {
    var a = apple_of(t, k)
    return Banana(a.grow())
}
