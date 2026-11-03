// See fmt.k. write! into a reused String (Display is shortest round-trip).
use std::fmt::Write;
fn main() {
    let n: i64 = std::env::var("N").unwrap().parse().unwrap();
    let mut buf = String::with_capacity(64);
    let mut chars = 0usize;
    for i in 0..n {
        let d = i as f64 * 0.37 + 0.001;
        buf.clear(); write!(buf, "{}", d).unwrap(); chars += buf.len();
        buf.clear(); write!(buf, "{}", i * 7919).unwrap(); chars += buf.len();
    }
    println!("{}", chars);
}
