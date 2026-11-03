// See dispatch.k. dyn Trait.
trait Shape { fn area(&self) -> i64; }
struct Rect { w: i64, h: i64 }
struct Square { s: i64 }
struct Tri { b: i64, h: i64 }
impl Shape for Rect { fn area(&self) -> i64 { self.w * self.h } }
impl Shape for Square { fn area(&self) -> i64 { self.s * self.s } }
impl Shape for Tri { fn area(&self) -> i64 { self.b * self.h / 2 } }

fn main() {
    let passes: i64 = std::env::var("N").unwrap().parse().unwrap();
    let shapes: Vec<Box<dyn Shape>> = (0..1024i64).map(|k| -> Box<dyn Shape> {
        match (k * 7919) % 3 {
            0 => Box::new(Rect { w: k % 13 + 1, h: k % 7 + 1 }),
            1 => Box::new(Square { s: k % 11 + 1 }),
            _ => Box::new(Tri { b: k % 17 + 2, h: k % 5 + 2 }),
        }
    }).collect();
    let mut total: i64 = 0;
    for _ in 0..passes { for s in &shapes { total += s.area(); } }
    println!("{}", total);
}
