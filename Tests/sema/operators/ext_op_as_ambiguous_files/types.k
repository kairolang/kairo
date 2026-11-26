pub struct M { pub var v: i32 }
pub struct N { pub var v: i32 }

pub struct Feet {
    pub var v: i32
    @implicit pub fn op as (const self) -> M { return M{v: self.v} }
}
