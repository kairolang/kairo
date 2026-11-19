// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: printf 'fn a()   {\n}\n' > %t.d/a.k
// RUN: printf 'fn b()   {\n}\n' > %t.d/b.k
// RUN: { %kfmt --write %t.d/a.k %t.d/missing.k %t.d/b.k 2>&1 || echo "exit=$?"; } | %FileCheck %s
// RUN: %FileCheck --strict-whitespace --check-prefix=A %s --input-file=%t.d/a.k
// RUN: %FileCheck --strict-whitespace --check-prefix=B %s --input-file=%t.d/b.k
//
// A path that does not exist is reported, the remaining files are still
// formatted, and the exit status is nonzero.

// CHECK: path does not exist: {{.*}}missing.k
// CHECK: exit=1
// A: fn a() {
// B: fn b() {
