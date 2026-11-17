// A generator meets an `I impl Iterator` bound through the generic
// `extend <T> Yield<T> impl Iterator`.
//
// Expected to fail: a generic extend that implements an interface with an associated
// type is not accepted as conforming (SC162E "'Yield<i32>' does not conform
// to 'Iterator': no member 'next' with the requirement's signature"); the
// same shape on a non-generic class conforms. Replace the XFAIL with the
// run when the compiler accepts it.

fn squares(n: i32) -> yield i32 {
    for var i = 0; i < n; i++ {
        yield i * i
    }
}

fn <I impl Iterator> count(it: I) -> i32 {
    var n = 0
    while true {
        var x = it.next()
        if !x? {
            break
        }

        n += 1
    }

    return n
}

fn main() -> i32 {
    return count(squares(3)) - 3
}

// --- lit wiring ---
// REQUIRES: newlib
// XFAIL: *
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
