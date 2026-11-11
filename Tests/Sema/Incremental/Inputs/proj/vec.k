pub struct V2 {
    pub var x: i32
    pub var y: i32
}

pub fn op + (a: V2, b: V2) -> V2 {
    return V2 { x: a.x + b.x, y: a.y + b.y }
}
// SLOT-op
