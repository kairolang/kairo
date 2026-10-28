// Corpus for Sema/Conversions/module_generic.k: the other module's side.

pub fn take_i64(x: i64) -> i64 { return x; }
pub fn take_f64(x: f64) -> f64 { return x; }
pub fn give_i32() -> i32 { return 7; }
pub fn give_f64() -> f64 { return 2.5; }
pub fn give_u32() -> u32 { return 3; }
pub fn give_u64() -> u64 { return 4; }

pub fn <T> pass(x: T) -> T { return x; }

pub class <T> Cell {
    pub var v: T;
    fn Cell(self, v: T) { self.v = v; }
    fn get(self) -> T { return self.v; }
    fn put(self, v: T) { self.v = v; }
}
