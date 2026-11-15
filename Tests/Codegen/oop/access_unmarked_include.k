// A method with no visibility written is `priv` (its file has no module.k
// above it) and `private:` in what C++ includes: a header and a kcc
// `#include "gauge.k"` stream. The record's friend lines are written there
// too, so the file's `pub inline` function, compiled in the C++ host's TU,
// still reaches the method; the host itself cannot (its static_assert), and
// naming the method is clang's error in the host's own file, not an
// internal one.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/access_unmarked_include && %kairo gauge.k --type-check-only --emit-headers %t.d/h
// RUN: cat %t.d/h/*.hh | tr -d '[:space:]' | %FileCheck %s --check-prefix=HDR
// HDR: private:__attribute{{(__)?}}((const))signedintpeek()constnoexcept;public:__attribute{{(__)?}}((pure))signedintopen()constnoexcept;friendsignedintread(::gauge::Gauge*g)noexcept;};
// RUN: cd %S/Inputs/access_unmarked_include && %kcc host.cpp -o %t.d/host
// RUN: %t.d/host
// RUN: cd %S/Inputs/access_unmarked_include && { %kcc -DPOKE -c host.cpp -o %t.d/poke.o 2>&1 || true; } | %FileCheck %s --check-prefix=POKE
// POKE: host.cpp:{{[0-9]+}}:{{[0-9]+}}: error
// POKE-SAME: 'peek' is a private member of 'gauge::Gauge'
// POKE-NOT: I003E
