// XFAIL: *
//
// Compiler defect: a list literal written as an argument of a call that
// names its generic arguments (`f<E>([1, 2])`) is rejected: the explicit
// generic argument is applied to the `reserve` and `push` calls the literal
// expands to ("candidate not viable: it takes 0 generic argument(s), and 1
// were written", then "needs the 'Vector' lang item"). A literal passed to a
// call that deduces its arguments compiles.
//
// Cases from Rust library/alloctests/tests/vec.rs
//   (test_dedup: a table of input and expected vectors)

import self::Inputs::counted::*

fn <E impl Elem> run_of(const keys: [i64], const want: [i64], const tag: string) requires E impl Eq {
    reset()
    {
        var v: [E]
        for var i: usize = 0; i < keys.size(); ++i {
            v.push(E::make(keys[i]))
        }

        v.dedup()
        expect(keys_are(v, want), f"{tag}: dedup")
    }

    expect_clean(f"{tag}: dedup run")
}

fn <E impl Elem> table(const tag: string) requires E impl Eq {
    run_of<E>([], [], f"{tag} []")
    run_of<E>([1, 1], [1], f"{tag} [1 1]")
    run_of<E>([1, 1, 2, 2, 2, 3, 3], [1, 2, 3], f"{tag} runs")
}

fn main() -> i32 {
    table<i32>("i32")
    table<string>("string")
    table<Counted>("Counted")
    table<RCounted>("RCounted")
    return finish()
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
