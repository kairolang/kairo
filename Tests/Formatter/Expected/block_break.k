// RUN: %kfmt --stdout %s | diff -u %S/Expected/block_break.k -
// RUN: %kfmt --check %S/Expected/block_break.k
//
// Rule 8.1 (decided 2026-11-08): every block breaks: `{` ends the
// header line, the body goes one level in, `}` stands alone, even for one
// simple statement that would fit (clang-format's
// AllowShortBlocksOnASingleLine: Never). An empty block stays `{ }`.

fn configure(want_tp: bool, want_tt: bool) {
    if want_tp {
        time_enable(true, want_tt)
    }
}

fn f(n: i32) -> i32 {
    loop {
        break
    }

    while n != 10 {
        n += 1
    }

    for var i: i32 = 0; i < 3; ++i {
        g(i)
    }

    if n > 0 {
        return n
    } else {
        return 0
    }

    unsafe {
        poke()
    }

    if n == 7 { }
    return n
}
