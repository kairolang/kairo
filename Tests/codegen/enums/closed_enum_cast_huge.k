// `v as E` into a closed, non-dense enum tests the operand with one
// `t != value` per variant, joined by `&&`. EmitIR parenthesises every
// binary operator, so a left-leaning chain over a registry-sized enum
// nested one bracket per variant and clang stopped at -fbracket-depth=2048
// (the diagnostic registry's DiagID, ~5000 variants). The chain is a
// balanced tree. RUN lines generate a 4000-variant enum (sparse values, so
// it is not dense) and check it compiles, links and runs: a listed value
// round-trips, an unlisted one crashes (134).
//
// This file's own body is the small shape; the huge one is built in %t.d.

enum Small derives u32 { A = 3, B = 9 }

fn main() -> i32 {
    var v: u32 = 9
    return (v as Small) as u32 as i32
}

// --- lit wiring ---
// REQUIRES: clang, long-tests
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: python3 -c "n=4000; print('enum Big derives u32 {'); print(',\n'.join('V%d = %d' % (i, i*7+3) for i in range(n))); print('}'); print('fn conv(v: u32) -> Big = v as Big'); print('fn main() -> i32 {'); print('    var ok = (conv(%d) == .V%d) && (conv(3) == .V0)' % ((n-1)*7+3, n-1)); print('    if !ok { return 1 }'); print('    var z = conv(4)'); print('    return 0'); print('}')" > %t.d/big.k
// RUN: %kairo %t.d/big.k -o %t.d/big.exe --cache-dir %t.d/c
// RUN: %t.d/big.exe; test $? -eq 134
