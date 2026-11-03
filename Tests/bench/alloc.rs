use std::hint::black_box;
struct P2 { a: i64, b: i64 }
static mut SINK: i64 = 0;
fn main() {
    let n: i64 = std::env::var("N").unwrap().parse().unwrap();
    for i in 0..n {
        let p = Box::new(P2 { a: i, b: 2 });
        let p = black_box(p);
        unsafe { SINK += p.a + p.b - 2; }
        drop(p);
    }
}
