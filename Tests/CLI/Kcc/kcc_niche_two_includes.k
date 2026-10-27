// A C++ TU that includes two Kairo modules, each defining enums, gets the
// niche trait (`__kairo_niche`, `__kairo_np`) once: an include's token
// stream carries no guard, so the second is skipped by the record of the
// first (IncludeEmitter's IncludedDecls). The host then sees the niche
// layouts Kairo does (spec ENUMLAYOUT §5): `Color?` tagged (a plain enum
// has no niche), a nullable pointer the pointer, a niche-filled ADT its
// payload.

// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/niche_host/niche_main.cpp -o %t.d/app 2>&1 | { grep -E 'error|redefinition' || true; } > %t.d/errs
// RUN: test ! -s %t.d/errs
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK: n 1 g 0 p 0 q 1
