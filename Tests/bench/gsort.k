import builtin::base::alloc::*
import std::io::println
ffi "c++" import "bench_env.h"

pub interface Less {
    fn op < (const self, const o: Self) -> bool
}

// Workaround: `extend i64 impl Less { fn op < }` emits a C++ operator< on a
// primitive (CL001E), so a wrapper type carries the order.
struct Key {
    var v: i64
    fn op < (const self, const o: Key) -> bool { return self.v < o.v }
}

struct Pair {
    var key: i64
    var val: i32
    fn op < (const self, const o: Pair) -> bool { return self.key < o.key }
}

fn <T impl Less> insertion(a: unsafe *T, lo: isize, hi: isize) {
    for var i = lo + 1; i <= hi; i += 1 {
        unsafe {
            var v: T = *(a + i)
            var j = i - 1
            while j >= lo && v < *(a + j) {
                *(a + j + 1) = *(a + j)
                j -= 1
            }
            *(a + j + 1) = v
        }
    }
}

fn <T impl Less> quicksort(a: unsafe *T, lo0: isize, hi0: isize) {
    var lo = lo0
    var hi = hi0
    while hi - lo > 16 {
        unsafe {
            var mid = lo + (hi - lo) / 2
            // median of three into a[mid]
            if *(a + mid) < *(a + lo) { var t: T = *(a + mid); *(a + mid) = *(a + lo); *(a + lo) = t }
            if *(a + hi) < *(a + lo) { var t: T = *(a + hi); *(a + hi) = *(a + lo); *(a + lo) = t }
            if *(a + hi) < *(a + mid) { var t: T = *(a + hi); *(a + hi) = *(a + mid); *(a + mid) = t }
            var pivot: T = *(a + mid)
            var i = lo
            var j = hi
            while i <= j {
                while *(a + i) < pivot { i += 1 }
                while pivot < *(a + j) { j -= 1 }
                if i <= j {
                    var t: T = *(a + i); *(a + i) = *(a + j); *(a + j) = t
                    i += 1
                    j -= 1
                }
            }
            // recurse into the smaller side, loop on the larger
            if j - lo < hi - i {
                quicksort<T>(a, lo, j)
                lo = i
            } else {
                quicksort<T>(a, i, hi)
                hi = j
            }
        }
    }
    insertion<T>(a, lo, hi)
}

fn <T, R> reduce(a: unsafe *T, n: isize, init: R, f: fn(R, T) -> R) -> R {
    var acc = init
    for var i: isize = 0; i < n; i += 1 { unsafe { acc = f(acc, *(a + i)) } }
    return acc
}

fn <T> count_if(a: unsafe *T, n: isize, pred: fn(T) -> bool) -> i64 {
    var c: i64 = 0
    for var i: isize = 0; i < n; i += 1 { unsafe { if pred(*(a + i)) { c += 1 } } }
    return c
}

static rng: u64 = 0x9E3779B97F4A7C15
fn next_rand() -> u64 {
    rng ^= rng << 13
    rng ^= rng >> 7
    rng ^= rng << 17
    return rng
}

fn main() -> i32 {
    var n = bench_n() as isize
    var xs: unsafe *Key = &null
    var ps: unsafe *Pair = &null
    unsafe {
        xs = alloc_raw((n as usize) * sizeof Key, alignof Key) as unsafe *Key
        ps = alloc_raw((n as usize) * sizeof Pair, alignof Pair) as unsafe *Pair
        for var i: isize = 0; i < n; i += 1 {
            var r = next_rand()
            *(xs + i) = Key { v: (r >> 1) as i64 }
            *(ps + i) = Pair { key: (r >> 20) as i64, val: i as i32 }
        }
    }
    quicksort<Key>(xs, 0, n - 1)
    quicksort<Pair>(ps, 0, n - 1)
    var sorted = true
    unsafe {
        for var i: isize = 1; i < n; i += 1 {
            if *(xs + i) < *(xs + i - 1) || (*(ps + i)).key < (*(ps + i - 1)).key { sorted = false }
        }
    }
    var sum = reduce<Key, i64>(xs, n, 0i64, fn (acc: i64, k: Key) -> i64 { return acc ^ (k.v + acc) })
    var big = count_if<Pair>(ps, n, fn (p: Pair) -> bool { return p.val % 3 == 0 })
    println(f"sorted {sorted} sum {sum} count {big}")
    return 0
}
