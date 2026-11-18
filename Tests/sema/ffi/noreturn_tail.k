// A `-> !` function whose body ends in a call to a header function. The call
// ends the path only when the header declares the function `[[noreturn]]`
// (imported, it then has type `!`). One that does not is SC105E, and the
// error says why in Kairo's terms: the C/C++ function returns, and where it
// is declared, rather than leaving the user to find it in the C++.

ffi "c++" import "noreturn_tail.h"

fn halts() -> ! {
    stop_here(1)
}

fn falls(n: i32) -> ! {
    keep_going(n)
}

fn nested(n: i32) -> ! {
    {
        keep_going(n);
    }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG:      noreturn_tail.k:15:1: error [SC105E]: 'falls' is declared to never return, but control can reach the end of its body
// DIAG-NEXT: noreturn_tail.k:13:4: note [SC105N]: declared '-> !' here
// DIAG-NEXT: noreturn_tail.k:14:5: note [SC105N]: 'keep_going' is a C/C++ function its header does not declare '{{\[\[noreturn\]\]}}', so in Kairo this call returns and does not end the path
// DIAG-NEXT: noreturn_tail.h:5:1: note [SC105N]: 'keep_going' declared here; only a '-> !' function or a C/C++ function declared '{{\[\[noreturn\]\]}}' (or '_Noreturn') has type '!'
// DIAG:      noreturn_tail.k:21:1: error [SC105E]: 'nested' is declared to never return
// DIAG:      noreturn_tail.k:19:9: note [SC105N]: 'keep_going' is a C/C++ function
