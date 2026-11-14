// What a call leaves moved-from crosses files: the function's own file
// records it, and a file that imports it reads the record.
//
// Inputs/partial_caller_files/acyclic: main.k imports lib.k, whose
// `take_a` leaves `self.a` and whose `drain` leaves its `@inout` argument's
// `b` moved-from. Both uses in main.k are errors, with a note in lib.k.
//
// Inputs/partial_caller_files/cycle: left.k and right.k import each other
// and each uses a part the other's function left moved-from. The files of
// a cycle are checked one after the other, so the one checked last reads
// the other's record: the use in the file the compiler was given is an
// error. The use in the other file is not reported (the record it needs is
// not written yet), and nothing is reported twice.

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/partial_caller_files/acyclic && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FLAT --implicit-check-not="error ["
// FLAT: main.k:6:12: error [SC052E]: 'h.a' is used after being moved
// FLAT: main.k:5:13: note [{{[A-Z0-9]+}}]: 'h.a' was moved here, by the call to 'take_a'
// FLAT: lib.k:13:41: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// FLAT: main.k:12:12: error [SC052E]: 'h.b' is used after being moved
// FLAT: main.k:11:13: note [{{[A-Z0-9]+}}]: 'h.b' was moved here, by the call to 'drain'
// FLAT: lib.k:16:48: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns

// RUN: cd %S/Inputs/partial_caller_files/cycle && { %kairo left.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=LEFT --implicit-check-not="error ["
// RUN: cd %S/Inputs/partial_caller_files/cycle && { %kairo left.k --type-check-only --sema-threads=1 2>&1 || true; } | %FileCheck %s --check-prefix=LEFT --implicit-check-not="error ["
// LEFT: left.k:21:12: error [SC052E]: 'h.b' is used after being moved

// RUN: cd %S/Inputs/partial_caller_files/cycle && { %kairo right.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=RIGHT --implicit-check-not="error ["
// RUN: cd %S/Inputs/partial_caller_files/cycle && { %kairo right.k --type-check-only --sema-threads=1 2>&1 || true; } | %FileCheck %s --check-prefix=RIGHT --implicit-check-not="error ["
// RIGHT: right.k:8:12: error [SC052E]: 'h.a' is used after being moved
