import shapes::*
pub struct Coin { pub var v: i32 }
extend Coin impl Make {
    pub static fn make() -> Coin = Coin { v: 5 }
    pub fn val(const self) -> i32 = self.v
}
pub class <K> Bag {
    pub var k: K
    pub fn Bag(self, k: K) { self.k = k }
}
pub class Purse impl Holder {
    type Inner = Coin
    pub fn Purse(self) { }
    pub fn inner(const self) -> Coin { return Coin { v: 2 } }
}
pub class Bank impl Store {
    type Item = Purse
    type <K> Map = Bag<K>
    pub fn Bank(self) { }
    pub fn get(const self) -> Purse { return Purse() }
    pub fn <K> wrap(const self, k: K) -> Bag<K> { return Bag<K>(k) }
    pub fn <K> unwrap(const self, m: Bag<K>) -> K { return m.k }
}
