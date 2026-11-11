pub interface Shape {
    fn area(self) -> i32
}

pub fn <T impl Shape> total(v: T) -> i32 {
    return v.area()
}

pub class <T> Holder {
    pub var v: T

    pub fn bad(self) -> i32 {
        var y = 1 as i32
        return y
    }
}
