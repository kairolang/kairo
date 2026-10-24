// Where kcc writes, as clang does: -c makes <stem>.o per input in the
// current directory, -o names the one output, -S the .s, -E writes to
// stdout or -o, a link with no -o is a.out, -fsyntax-only writes nothing,
// and the last of -c / -S wins. A .k is an input like any other.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d/c1 %t.d/c2 %t.d/c3 %t.d/s %t.d/e %t.d/l %t.d/k %t.d/n
// RUN: printf 'int a() { return 1; }\n' > %t.d/a.cc
// RUN: printf 'int b() { return 2; }\n' > %t.d/b.cc
// RUN: printf 'int a(); int b();\nint main() { return a() + b(); }\n' > %t.d/m.cc
// RUN: printf 'pub fn k() -> i32 { return 4; }\n' > %t.d/y.k

// RUN: cd %t.d/c1 && %kcc -c %t.d/a.cc %t.d/b.cc && test "$(ls)" = "$(printf 'a.o\nb.o')"
// RUN: cd %t.d/c2 && %kcc -c %t.d/a.cc -o x.o && test "$(ls)" = "x.o"
// RUN: cd %t.d/c3 && { %kcc -c %t.d/a.cc %t.d/b.cc -o x.o 2>&1 || true; } | %FileCheck %s --check-prefix=MANY
// RUN: cd %t.d/c3 && test -z "$(ls)"
// MANY: fatal [I004F]: -o x.o names one output, but this build emits 2

// RUN: cd %t.d/s && %kcc -S %t.d/a.cc && test "$(ls)" = "a.s" && grep -q '_Z1av' a.s
// RUN: cd %t.d/s && %kcc -c %t.d/b.cc -S && test -e b.s && test ! -e b.o
// RUN: cd %t.d/e && %kcc -E %t.d/a.cc | grep -q 'int a()' && test -z "$(ls)"
// RUN: cd %t.d/e && %kcc -E %t.d/a.cc -o a.i && grep -q 'int a()' a.i

// RUN: cd %t.d/l && %kcc %t.d/a.cc %t.d/b.cc %t.d/m.cc && test "$(ls)" = "a.out"
// RUN: %t.d/l/a.out; test $? -eq 3
// RUN: cd %t.d/l && %kcc %t.d/a.cc %t.d/b.cc %t.d/m.cc -o app && ./app; test $? -eq 3

// RUN: cd %t.d/k && %kcc -c %t.d/y.k && test "$(ls)" = "y.o"
// RUN: cd %t.d/k && %kcc -c %t.d/y.k -o z.o && test -e z.o

// RUN: cd %t.d/n && %kcc -fsyntax-only %t.d/a.cc %t.d/y.k && test -z "$(ls)"
// RUN: cd %t.d/n && { %kcc %t.d/nope.cc 2>&1 || true; } | %FileCheck %s --check-prefix=NOPE
// RUN: cd %t.d/n && not %kcc %t.d/nope.cc 2> /dev/null
// NOPE: no such file or directory: '{{.*}}nope.cc'
