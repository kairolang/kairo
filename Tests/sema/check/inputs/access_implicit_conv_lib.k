// A private `@implicit op as`, a private explicit one, and the uses its
// own file may make of them: the class's own members, a free function and
// an extension of the class in this file, a member lookup through one
// included.

pub class Meters {
    pub var n: i32

    pub fn Meters(self, n: i32) { self.n = n }

    @implicit priv fn op as (const self) -> i64 { return self.n }

    pub fn widened(const self) -> i64 {
        var w: i64 = self
        return w
    }
}

pub class Inch {
    pub var n: i32

    pub fn Inch(self, n: i32) { self.n = n }

    priv fn op as (const self) -> f64 { return self.n }
}

// A member a Yard lacks is looked up on the Feet its conversion yields.
pub class Feet {
    pub var n: i32

    pub fn Feet(self, n: i32) { self.n = n }

    pub fn twice(const self) -> i32 { return self.n * 2 }
}

pub class Yard {
    pub var n: i32

    pub fn Yard(self, n: i32) { self.n = n }

    @implicit priv fn op as (const self) -> Feet { return Feet(self.n * 3) }

    pub fn own_twice(const self) -> i32 { return self.twice() }
}

fn take_wide(x: i64) -> i64 { return x }

pub fn lib_uses(m: Meters, i: Inch, y: Yard) -> i64 {
    var t = y.twice()
    var a = take_wide(m)
    var b = m as i64
    var c = i as f64
    return a + b + (c as i64)
}

extend Meters {
    pub fn doubled(const self) -> i64 { return take_wide(self) * 2 }
}
