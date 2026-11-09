// Corpus for Sema/Check/visibility_module.k: a file of the geo module.
prot fn scale() -> i32 { return 2 }
fn unit() -> i32 { return 1 }
priv fn secret() -> i32 { return 9 }

pub class Shape {
    pub fn Shape(self) { }
    prot var sides: i32 = 4
    var tag: i32 = 7
    prot fn area(const self) -> i32 { return self.sides * 2 }
    priv fn inner(const self) -> i32 { return 1 }
}
