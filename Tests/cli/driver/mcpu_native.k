// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --mcpu native -o %t.d/a.out --cache-dir %t.d/c
// RUN: %t.d/a.out; test $? -eq 7
// RUN: { %kairo %s --mcpu native --target aarch64-unknown-linux-gnu --type-check-only 2>&1 || true; } | %FileCheck %s
// `--mcpu native` is the host's CPU, as clang's -mcpu=native is:
// resolved by kairo (cc1's -target-cpu has no `native`). With --target the
// host names nothing about the target, so it is an error, not a guess.
// CHECK: error [P006E]: '--mcpu native' names the host CPU and cannot be used with --target 'aarch64-unknown-linux-gnu'
// CHECK-NOT: unknown target CPU 'native'

fn main() -> i32 {
    return 7
}
