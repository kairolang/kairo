pub fn <T> first(a: T, b: T) -> T {
    return a;
}

pub inline fn sq(x: i32) -> i32 {
    return x * x;
}

pub class <T> Box {
    pub var v: T;

    pub fn get(self) -> T {
        return self.v;
    }
}

pub fn use_box() -> i32 {
    var b = Box<i32>();
    b.v = 5;
    return b.get() + first(1, 2);
}
