pub class <T> Pool {
    pub static live: i32 = 1
    pub static cap: i32
    pub var v: T
    pub fn Pool(self, v: T) { self.v = v  Pool<T>::live += 1 }

    pub struct Slot {
        pub static used: i32 = 3
        pub var x: T
    }
}
