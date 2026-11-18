pub struct P {
    pub var x: i32
    pub var y: i32
}

pub enum Mode derives u8 {
    Off = 0,
    On  = 3,
}

pub class Box {
    priv var v: i32 = 0

    pub fn Box(self, v: i32) {
        self.v = v
    }

    pub fn get(self) -> i32 {
        return self.v
    }

    pub fn op + (self, o: i32) -> i32 {
        return self.v + o
    }
}

extend P {
    pub fn sum(self) -> i32 = self.x + self.y
}

pub module util {
    pub fn helper(v: i32) -> i32 {
        return v
    }
}

pub fn add(a: i32, b: i32) -> i32 {
    return a + b
}

pub fn add(a: i64, b: i64) -> i64 {
    return a + b
}

pub fn <T> ident(v: T) -> T {
    return v
}

pub eval LIMIT: i32 = 4

pub type Id = i32
