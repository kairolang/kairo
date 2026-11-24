// A MinGW link that runs out of process (an -mllvm word sends it to kld) and
// whose argv is past the command-line limit goes through a response file.
// lld's MinGW driver has no --rsp-quoting, so the runner must not pass it one.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// REQUIRES: kld
// REQUIRES: sysroot-x86_64-windows-gnu
// RUN: rm -f %t.exe
// RUN: %kairo %s --target=x86_64-w64-mingw32 -o %t.exe --ld-flags=-mllvm --ld-flags=-compute-dead=false $(for i in $(seq 1 800); do echo "--ld-flags=-L%t.d/no-such-directory-$i"; done)
// RUN: test -f %t.exe
