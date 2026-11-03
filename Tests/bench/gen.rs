fn upto(n: i64) -> impl Iterator<Item = i64> { 0..n }
fn squares(n: i64) -> impl Iterator<Item = i64> { upto(n).map(|v| v * v % 1000003) }
fn evens(n: i64) -> impl Iterator<Item = i64> { squares(n).filter(|v| v % 2 == 0) }
fn main() {
    let n: i64 = std::env::var("N").unwrap().parse().unwrap();
    let sum: i64 = evens(n).sum();
    println!("{}", sum);
}
