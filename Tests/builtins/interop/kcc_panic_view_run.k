// The C++ view of a panic result (`builtin::panic_error<E>` and its what()
// text) behind a C++ include of a module of the two-word library: the
// message's bytes are read through string's extension members, data() and
// size(). The same host and module as cli/kcc/kcc_panic_cxx_view.k.

// --- lit wiring ---
// REQUIRES: newlib, kcc
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc_new %S/../../cli/kcc/inputs/panic_view/view_main.cpp -o %t.d/app
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
