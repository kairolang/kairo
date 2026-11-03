#[derive(Clone, Copy, PartialEq, PartialOrd)]
struct Key { v: i64 }
#[derive(Clone, Copy)]
struct Pair { key: i64, val: i32 }
impl PartialEq for Pair { fn eq(&self, o: &Self) -> bool { self.key == o.key } }
impl PartialOrd for Pair { fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> { self.key.partial_cmp(&o.key) } }

fn insertion<T: PartialOrd + Copy>(a: &mut [T]) {
    for i in 1..a.len() {
        let v = a[i];
        let mut j = i;
        while j > 0 && v < a[j - 1] { a[j] = a[j - 1]; j -= 1; }
        a[j] = v;
    }
}

fn quicksort<T: PartialOrd + Copy>(mut a: &mut [T]) {
    while a.len() > 17 {
        let (lo, hi) = (0, a.len() - 1);
        let mid = hi / 2;
        if a[mid] < a[lo] { a.swap(mid, lo); }
        if a[hi] < a[lo] { a.swap(hi, lo); }
        if a[hi] < a[mid] { a.swap(hi, mid); }
        let pivot = a[mid];
        let (mut i, mut j) = (lo as isize, hi as isize);
        while i <= j {
            while a[i as usize] < pivot { i += 1; }
            while pivot < a[j as usize] { j -= 1; }
            if i <= j { a.swap(i as usize, j as usize); i += 1; j -= 1; }
        }
        let (left, right) = a.split_at_mut(i as usize);
        let left = &mut left[..(j + 1) as usize];
        if left.len() < right.len() { quicksort(left); a = right; } else { quicksort(right); a = left; }
    }
    insertion(a);
}

fn main() {
    let n: usize = std::env::var("N").unwrap().parse().unwrap();
    let lib = std::env::var("LIBSORT").is_ok();
    let mut rng: u64 = 0x9E3779B97F4A7C15;
    let mut next = || { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; rng };
    let mut xs = Vec::with_capacity(n);
    let mut ps = Vec::with_capacity(n);
    for i in 0..n { let r = next(); xs.push(Key { v: (r >> 1) as i64 }); ps.push(Pair { key: (r >> 20) as i64, val: i as i32 }); }
    if lib {
        xs.sort_unstable_by(|a, b| a.v.cmp(&b.v));
        ps.sort_unstable_by(|a, b| a.key.cmp(&b.key));
    } else {
        quicksort(&mut xs);
        quicksort(&mut ps);
    }
    let sorted = xs.windows(2).all(|w| !(w[1] < w[0])) && ps.windows(2).all(|w| w[1].key >= w[0].key);
    let sum = xs.iter().fold(0i64, |acc, k| acc ^ k.v.wrapping_add(acc));
    let big = ps.iter().filter(|p| p.val % 3 == 0).count();
    println!("sorted {} sum {} count {}", sorted, sum, big);
}
