// The C++ view of a panicking Kairo function (PANIC.md §4.6): a C++ host
// (Inputs/panic_view: view.k, view_main.cpp) reads the result with the
// `::builtin` helpers -- ok, value, is<E>, error<E>, site, type_id<E>, the
// panic_set trait with its payload offset -- and converts it to an
// exception with value_or_throw: panic_error<E> for the E it holds, caught
// as itself, as panic_error_base, or as std::exception.
//
// what() is `<op panic message> [<Type> at <file>:<line>:<col>]`, from the
// type's own `op panic` (ConfigError) or an `extend`'s (Odd), and just
// `<Type> at <file>:<line>:<col>` without one (Plain, Big). The site comes
// from the linker-collected site table. A void result, an lvalue result
// (copied out), and a move-only error (moved into the exception, its copies
// sharing one what() buffer) work too. Checked under valgrind by hand (a
// glibc build: --target=x86_64-unknown-linux-gnu, -O0 and -O2): no error,
// nothing in use at exit.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/panic_view/view_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      ok 1 value 10
// CHECK-NEXT: ok 0 is<ConfigError> 1 is<Plain> 0 is<int> 0 key 7
// CHECK-NEXT: site {{.*}}view.k:35:17
// CHECK-NEXT: ok has no site 1
// CHECK-NEXT: set size 3 offset 8 tag is id 1
// CHECK-NEXT: value_type int 1
// CHECK-NEXT: value_or_throw 8
// CHECK-NEXT: ConfigError key 7 type 1 what: missing config key [ConfigError at {{.*}}view.k:35:17]
// CHECK-NEXT: base what: Plain at {{.*}}view.k:36:17
// CHECK-NEXT: std what: odd value [Odd at {{.*}}view.k:37:17]
// CHECK-NEXT: lvalue key 7 still 7
// CHECK-NEXT: void n -2 what: Plain at {{.*}}view.k:42:16
// CHECK-NEXT: big -4 same text 1 what: Big at {{.*}}view.k:46:16
// CHECK-EMPTY:
