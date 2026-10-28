// __builtin_signal: the message, then the signal at its default action
// (SIGTERM: the shell reports 128 + 15).

fn main() -> i32 {
    var m = "sig"
    __builtin_signal(m.data, m.len, SIGNAL::SIGTERM)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, host-linux
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe 2> %t.err; test $? -eq 143
// RUN: grep -q sig %t.err
