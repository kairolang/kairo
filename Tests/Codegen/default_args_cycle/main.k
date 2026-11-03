// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
//
// Defaults across an import cycle: a calls b's defaulted function and b
// calls a's. The two TUs lower in lockstep, so one TU mints the thunk for
// a default written in the other before that TU is lowered. The thunk was
// then never placed and CallLowering ICE'd ("a default thunk was minted but
// the declaration that wrote the default was never visited"; the self-host
// whole-tree check). The declaring TU now places it.

import a::*
import b::*

fn main() -> i32 {
    // a_val: b_def() = 3, + 1 = 4; b_use: a_def() = 2
    return a_val() + b_use()
}
