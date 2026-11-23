// A program built for the host's CPU (no --target, --march or --mcpu) runs
// on the host and computes what the same program built for the baseline CPU
// computes. The sums are exact in f64 whether or not a multiply and an add
// fuse, so the two builds must agree to the bit.

fn dot(n: i32) -> f64 {
    var acc: f64 = 0.0
    for var i: i32 = 1; i <= n; ++i {
        var x = i as f64
        acc = acc + x * 0.5 + 0.25
    }

    return acc
}

fn main() -> i32 {
    var s: i64 = 0
    for var i: i64 = 0; i < 1000; ++i {
        s += (i * i) % 7
    }

    // sum(i / 2 + 1 / 4, i = 1..64) = 1040 + 16 = 1056; s = 2001.
    if dot(64) != 1056.0 {
        return 1
    }

    return ((s % 100) as i32) + 2
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -f %t.host.exe %t.base.exe
// RUN: %kairo %s -O2 --mcpu= -o %t.host.exe
// RUN: %t.host.exe; test $? -eq 3
// RUN: %kairo %s -O2 -o %t.base.exe
// RUN: %t.base.exe; test $? -eq 3
