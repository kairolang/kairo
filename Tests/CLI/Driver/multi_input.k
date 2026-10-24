// Several Kairo files on one command line. Every input reaches builtin, and
// one may import another: each file goes through the pipeline once, under
// the module identity its importer gives it, whatever order the command
// line names them in. Each of these crashed (a frozen symbol table taking
// inserts) or failed to resolve `foo` before.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// Unrelated inputs share builtin and std.
// RUN: cd %t.d && %kairo --type-check-only %S/Inputs/multi_input/other.k %S/Inputs/multi_input/foo.k

// The importer first: foo.k is its import, and then has nothing left to do.
// f(2) prints, then f(3) is the exit status.
// RUN: cd %t.d && %kairo %S/Inputs/multi_input/main.k %S/Inputs/multi_input/foo.k %S/Inputs/multi_input/other.k -o %t.d/a --cache-dir %t.d/o1
// RUN: %t.d/a > %t.d/a.out; test $? -eq 6
// RUN: %FileCheck %s --input-file=%t.d/a.out
// CHECK:      f
// CHECK-NEXT: main 4
// CHECK-NEXT: f

// The import first, and named twice: it is still module foo to main.k, and
// one object.
// RUN: cd %t.d && %kairo %S/Inputs/multi_input/foo.k %S/Inputs/multi_input/other.k %S/Inputs/multi_input/main.k %S/Inputs/multi_input/foo.k -o %t.d/b --cache-dir %t.d/o2
// RUN: %t.d/b > %t.d/b.out; test $? -eq 6
// RUN: %FileCheck %s --input-file=%t.d/b.out
// RUN: test $(find %t.d/o2 -name foo.o | wc -l) -eq 1

// Builtin claimed by the first input, std::io by the second: its inline
// bodies still get builtin's ffi headers (rt/fmt.h).
// RUN: cd %t.d && %kairo %S/Inputs/multi_input/other.k %S/Inputs/multi_input/main.k %S/Inputs/multi_input/foo.k -o %t.d/c --cache-dir %t.d/o3
// RUN: %t.d/c; test $? -eq 6
