// #include "foo.k" under the preprocessor rules a header follows, as
// clang's own Preprocessor tests check them for C/C++ headers: include-once
// through #pragma once and guard macros, __has_include, #if 0 and #ifdef,
// angled includes through -I, subdirectory paths, -iquote, #import, -E, and
// host macros, which never rewrite the Kairo stream.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d

// geo.k reached five times: two #pragma once headers, a guarded header
// twice, and directly. 2 + 4 + 6.
// RUN: %kcc %S/Inputs/pp/once.cc -o %t.d/once && %t.d/once; test $? -eq 12

// Headers that include each other (each #pragma once): the scan that finds
// geo.k must stop, and does. 3 + 4.
// RUN: %kcc %S/Inputs/pp/cycle.cc -o %t.d/cycle && %t.d/cycle; test $? -eq 7

// __has_include sees a .k as clang sees any file. 20 + 1.
// RUN: %kcc %S/Inputs/pp/has_include.cc -o %t.d/has && %t.d/has; test $? -eq 21

// A .k behind #if 0 is never included (the scan still builds it).
// RUN: %kcc %S/Inputs/pp/if0.cc -o %t.d/if0 && %t.d/if0; test $? -eq 10

// #ifdef chooses the include: with -DUSE_GEO 30 + 3, without 1.
// RUN: %kcc -DUSE_GEO %S/Inputs/pp/ifdef.cc -o %t.d/def && %t.d/def; test $? -eq 33
// RUN: %kcc %S/Inputs/pp/ifdef.cc -o %t.d/nodef && %t.d/nodef; test $? -eq 1

// An angled include through -I, found and built without being named. 9 + 16.
// RUN: %kcc -I %S/Inputs/pp/lib %S/Inputs/pp/angled.cc -o %t.d/angled && %t.d/angled; test $? -eq 25
// RUN: { %kcc %S/Inputs/pp/angled.cc -o %t.d/noI 2>&1 || true; } | %FileCheck %s --check-prefix=NOI
// NOI: angled.cc:1:10: error [CL001E]: 'vec.k' file not found

// A path into a subdirectory. 1 + 4.
// RUN: %kcc %S/Inputs/pp/subdir.cc -o %t.d/sub && %t.d/sub; test $? -eq 5

// -iquote directories, for quoted includes only.
// RUN: %kcc -iquote %S/Inputs/pp/quote %S/Inputs/pp/iquote.cc -o %t.d/iq && %t.d/iq; test $? -eq 8
// RUN: { %kcc %S/Inputs/pp/iquote.cc -o %t.d/noiq 2>&1 || true; } | %FileCheck %s --check-prefix=NOIQ
// NOIQ: iquote.cc:1:10: error [CL001E]: 'inner.k' file not found

// Host macros that name C++ keywords and Kairo names alike: the stream is
// tokens, not text, and nothing in it expands. 40 + 2.
// RUN: %kcc %S/Inputs/pp/macros.cc -o %t.d/macros && %t.d/macros; test $? -eq 42

// Objective-C++ #import is include-once too. 6 + 1.
// RUN: %kcc %S/Inputs/pp/import.mm -o %t.d/import && %t.d/import; test $? -eq 7

// -E keeps clang's line markers for the .k, and its output builds alone.
// RUN: %kcc -E %S/Inputs/pp/once.cc -o %t.d/once.ii
// RUN: %FileCheck %s --check-prefix=PP --input-file=%t.d/once.ii
// PP: # 1 "{{.*}}geo.k" 1
// PP: namespace geo {
// RUN: %kcc %t.d/once.ii %S/Inputs/pp/geo.k -o %t.d/once_ii && %t.d/once_ii; test $? -eq 12
