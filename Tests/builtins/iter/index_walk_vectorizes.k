// A for loop over a builtin container's walk vectorizes on baseline x86-64
// (no --march): a vector (through a const and a mutable binding), a vector's
// iter() and iter_mut(), a map's pairs (const and mutable), keys() and
// values(), a set, a slice and a fixed array. The container walks count an
// index; the loop vectorizer's cost model on SSE2 refuses a pointer walked to
// an end pointer. Run, the same functions give the item loop's answers.

import std::io::println

@no_inline
pub fn vec_sum(const v: [i32]) -> i64 {
    var s: i64 = 0
    for x in v {
        s += x
    }

    return s
}

@no_inline
pub fn vec_scale(v: *[i64]) {
    for *x in *v {
        *x = *x * 3 + 1
    }
}

@no_inline
pub fn iter_sum(const v: [i32]) -> i64 {
    var s: i64 = 0
    for p in v.iter() {
        s += *p
    }

    return s
}

@no_inline
pub fn iter_mut_add(v: *[i32]) {
    for p in v->iter_mut() {
        *p += 5
    }
}

@no_inline
pub fn pair_sum(const m: {u64: u64}) -> u64 {
    var s: u64 = 0
    for (k, v) in m {
        s += v
    }

    return s
}

@no_inline
pub fn key_sum(const m: {u64: u64}) -> u64 {
    var s: u64 = 0
    for *k in m.keys() {
        s += *k
    }

    return s
}

@no_inline
pub fn value_sum(const m: {u64: u64}) -> u64 {
    var s: u64 = 0
    for *v in m.values() {
        s += *v
    }

    return s
}

@no_inline
pub fn set_sum(const s: {u64}) -> u64 {
    var a: u64 = 0
    for x in s {
        a += x
    }

    return a
}

@no_inline
pub fn first_at(const v: [i32], k: i32) -> i64 {
    var i: i64 = 0
    for x in v {
        if x == k {
            return i
        }

        i += 1
    }

    return -1
}

@no_inline
pub fn pair_sum_mut(m: *{u64: u64}) -> u64 {
    var s: u64 = 0
    for (k, v) in *m {
        s += v
    }

    return s
}

@no_inline
pub fn slice_sum(const s: [const i32;]) -> i64 {
    var t: i64 = 0
    for x in s {
        t += x
    }

    return t
}

@no_inline
pub fn array_sum(const a: [i32; 64]) -> i64 {
    var t: i64 = 0
    for x in a {
        t += x
    }

    return t
}

fn main() -> i32 {
    var v: [i32]
    var w: [i64]
    var m: {u64: u64}
    var s: {u64}
    for var i: i32 = 0; i < 1000; i += 1 {
        v.push(i)
        w.push(i as i64)
        m.insert(i as u64, (i as u64) * 2)
        s.insert(i as u64)
    }

    vec_scale(&w)
    iter_mut_add(&v)
    var scaled: i64 = 0
    for x in w {
        scaled += x
    }

    println(f"vec_sum {vec_sum(v)}")
    println(f"iter_sum {iter_sum(v)}")
    println(f"scaled {scaled}")
    println(f"pair_sum {pair_sum(m)}")
    println(f"key_sum {key_sum(m)}")
    println(f"value_sum {value_sum(m)}")
    println(f"set_sum {set_sum(s)}")
    println(f"pair_sum_mut {pair_sum_mut(&m)}")
    var sl: [const i32;] = v
    println(f"slice_sum {slice_sum(sl)}")
    var a: [i32; 64]
    for var i: i32 = 0; i < 64; i += 1 {
        a[i] = i
    }

    println(f"array_sum {array_sum(a)}")
    println(f"first_at {first_at(v, 12)} {first_at(v, -3)}")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.ll --cache-dir %t.d
// RUN: %FileCheck %s --check-prefix=IR < %t.ll
// IR-LABEL: define {{.*}}@_ZN{{.*}}7vec_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}9vec_scale
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret void
// IR-LABEL: define {{.*}}@_ZN{{.*}}8iter_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}12iter_mut_add
// IR:       {{<[0-9]+ x i32>}}
// IR:       ret void
// IR-LABEL: define {{.*}}@_ZN{{.*}}8pair_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}7key_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}9value_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}7set_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}12pair_sum_mut
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}9slice_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64
// IR-LABEL: define {{.*}}@_ZN{{.*}}9array_sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64

// REQUIRES: clang
// RUN: rm -rf %t.r.d %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.r.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      vec_sum 504500
// OUT-NEXT: iter_sum 504500
// OUT-NEXT: scaled 1499500
// OUT-NEXT: pair_sum 999000
// OUT-NEXT: key_sum 499500
// OUT-NEXT: value_sum 999000
// OUT-NEXT: set_sum 499500
// OUT-NEXT: pair_sum_mut 999000
// OUT-NEXT: slice_sum 504500
// OUT-NEXT: array_sum 2016
// OUT-NEXT: first_at 7 -1
