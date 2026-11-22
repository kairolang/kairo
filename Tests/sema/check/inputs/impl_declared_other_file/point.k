import shape::Shape
pub class Point impl Shape {
    pub var x: i32 = 3
    pub fn area(const self) -> i32 { return self.x }
}

// Corpus for sema/check/impl_declared_other_file.k (its checks name line 2
// of this file): Point declares `impl Shape`, but its `name` is in
// point_name.k, which this file does not import.
