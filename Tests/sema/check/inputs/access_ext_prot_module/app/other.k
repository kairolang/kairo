import lib::base::Base
pub class Derived derives Base {
    var own: i32 = 3
    pub fn in_body(self) -> i32 { return self.ctx }
}
