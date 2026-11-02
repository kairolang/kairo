fn fannkuch(n: usize) -> (i32, i32) {
    let mut perm = [0usize; 16];
    let mut perm1 = [0usize; 16];
    let mut count = [0usize; 16];
    for (i, p) in perm1.iter_mut().enumerate().take(n) { *p = i; }
    let (mut max_flips, mut checksum, mut perm_count, mut r) = (0, 0, 0, n);
    loop {
        while r != 1 { count[r - 1] = r; r -= 1; }
        perm = perm1;
        let mut flips = 0;
        let mut k = perm[0];
        while k != 0 {
            perm[..=k].reverse();
            flips += 1;
            k = perm[0];
        }
        max_flips = max_flips.max(flips);
        checksum += if perm_count % 2 == 0 { flips } else { -flips };
        loop {
            if r == n { return (checksum, max_flips); }
            perm1[..=r].rotate_left(1);
            count[r] -= 1;
            if count[r] > 0 { break; }
            r += 1;
        }
        perm_count += 1;
    }
}

fn main() {
    let n: usize = std::env::var("N").unwrap().parse().unwrap();
    let (checksum, flips) = fannkuch(n);
    println!("{}\nPfannkuchen({}) = {}", checksum, n, flips);
}
