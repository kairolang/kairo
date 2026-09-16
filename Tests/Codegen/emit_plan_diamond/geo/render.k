import vec
import shape
import text

pub fn draw(c: *shape::Circle) -> f64 { return c->area(); }
pub fn place(l: text::Label) -> f64 { return l.pos.len(); }
pub fn boxed(v: f64) -> vec::Box<f64> { return vec::Box<f64>{ val: v }; }
