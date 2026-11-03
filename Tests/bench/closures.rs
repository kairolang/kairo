// See closures.k. Box<dyn Fn>: the stored, type-erased callback.
fn main() {
    let n: i64 = std::env::var("N").unwrap().parse().unwrap();
    let (k1, k2, k3) = (3i64, 1000003i64, 7i64);
    let stages: [Box<dyn Fn(i64) -> i64>; 3] = [
        Box::new(move |x| x.wrapping_mul(k1).wrapping_add(1)),
        Box::new(move |x| x % k2),
        Box::new(move |x| x ^ k3),
    ];
    let mut acc: i64 = 0;
    for i in 0..n {
        let v = stages.iter().fold(i, |v, f| f(v));
        acc = acc.wrapping_add(v);
    }
    println!("{}", acc);
}
