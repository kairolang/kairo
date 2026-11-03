struct Bad { _code: i32 }
fn parse(x: i64) -> Result<i64, Bad> { if x % 100 == 0 { return Err(Bad { _code: 1 }); } Ok(x * 3) }
fn main() { let n: i64 = std::env::var("N").unwrap().parse().unwrap(); let (mut sum, mut fails) = (0i64, 0i64);
  for i in 1..=n { match parse(i) { Ok(v) => sum += v, Err(_) => fails += 1 } }
  println!("{} {}", sum, fails); }
