// a.k and b.k import each other, so their headers include each other: a
// Basket holds an Apple, and Apple's bodies make Bananas.
import self::b::*

pub class Apple {
    pub var n: i32

    pub fn Apple(self, n: i32) {
        self.n = n
    }

    pub fn grow(self) -> i32 {
        var b = Banana(self.n)
        return b.peel() + 1
    }
}

pub fn apple_count(k: i32) -> i32 {
    return k + 1
}

pub fn <T> apple_of(const t: T, k: i32) -> Apple {
    var b = Banana(k)
    return Apple(b.peel())
}
