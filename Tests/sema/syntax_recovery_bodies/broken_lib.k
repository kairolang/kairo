pub fn helper(v: i32) -> i32 {
    return v + 1
}

pub class Shape {
    pub var w: i32 = 0

    pub fn Shape(self, w: i32) {
        self.w = ;
    }

    pub fn area(self) -> i32 {
        var x = self.w * ;
        return x
    }

    pub fn grow(self, by: i32) -> i32 {
        return self.w + by
    }
}

pub interface Named {
    fn name(self) -> i32
}

pub class Dog impl Named {
    pub fn Dog(self) { }

    pub fn name(self) -> i32 {
        return (1 + )
    }
}

pub fn above(v: i32) -> i32 {
    return helper(v)
}

pub fn bad(v: i32, unused: string) -> i32 {
    var (a, b) = (v + , 2)
    return a
}

pub fn below(v: i32) -> i32 {
    return above(v) + 1
}
