pub class Point {
    var x: i32 = 3
    pub var y: i32 = 4
    pub fn Point(self) { }
}
extend Point { pub fn twice(const self) -> i32 { return self.x * 2 } }

// Corpus for Sema/Check/access_ext_other_file.k: defines the type. The
// extension above is in the type's file, so it reads `x`.
