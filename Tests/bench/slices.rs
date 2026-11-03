// See slices.k.
fn main() {
    let passes: i64 = std::env::var("N").unwrap().parse().unwrap();
    let n = 1usize << 20;
    let xs: Vec<f64> = (0..n).map(|i| (i % 1000) as f64 * 0.5).collect();
    let ys: Vec<f64> = (0..n).map(|i| (i % 37) as f64 * 0.25).collect();
    let (mut sum, mut dot, mut big) = (0.0f64, 0.0f64, 0i64);
    for _ in 0..passes {
        sum += xs.iter().sum::<f64>();
        dot += xs.iter().zip(&ys).map(|(x, y)| x * y).sum::<f64>();
        big += ys.iter().filter(|&&y| y > 4.0).count() as i64;
    }
    println!("{} {} {}", sum as i64, dot as i64, big);
}
