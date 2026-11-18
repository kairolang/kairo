// A split subscript as C++ sees it: `Two`'s read form hands out `r`,
// its place form `w`. C++ reaches both through `operator[]`, the place form
// on a mutable object and the read form on a const one. `Keyed`'s two forms
// take one index type and the same `self`, so they would be one C++
// overload: the place form takes `operator[]`, and the read form is reached
// by its name, `__kairo_op_get`.

pub class Two {
    pub var r: [i32; 4]
    pub var w: [i32; 4]
    pub fn Two(self) {
        self.r = [10, 20, 30, 40]
        self.w = [0, 0, 0, 0]
    }

    pub fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
    pub fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

pub class Keyed {
    pub var v: [i32; 2]
    pub fn Keyed(self) { self.v = [3, 4] }
    pub fn op [] (self, k: i64) -> i32 { return self.v[0] + 100 }
    pub fn op []= (self, k: i64) -> *i32 { return &self.v[1] }
}
