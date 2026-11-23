// On a target with no fused multiply-add (baseline x86-64) Kairo does not
// contract by default, so a * b + c rounds the same way wherever it is
// evaluated. Contracted, the multiply and the add would run as two
// operations but fold as one fused operation when the operands are
// constants: 0.1 * 10.0 - 1.0 is 0 computed and 5.55e-17 folded. Here the
// folded call (folded), the run-time call (computed) and the two-statement
// form (split) must all give 0.

fn mac(a: f64, b: f64, c: f64) -> f64 {
    return a * b + c
}

fn split(a: f64, b: f64, c: f64) -> f64 {
    var t = a * b
    return t + c
}

fn folded() -> f64 {
    return mac(0.1, 10.0, -1.0)
}

fn main(argc: i32) -> i32 {
    var n      = argc as f64
    var r: i32 = 0
    if mac(0.1 * n, 10.0 * n, -1.0 * n) != 0.0 {
        r += 1
    }

    if split(0.1 * n, 10.0 * n, -1.0 * n) != 0.0 {
        r += 2
    }

    if folded() != 0.0 {
        r += 4
    }

    return r
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot, host-x86_64
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe
// RUN: %t.exe; test $? -eq 0
