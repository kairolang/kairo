// A record's C++ text -- its access levels and its friend list -- is a
// function of its own file only, so it is one text in every view of it:
// the module's own TU, an importer's TU, the module's header, and a C++
// host's `#include "vault.k"` stream (kcc). Each view below is checked
// against the same VIEW lines. It matters beyond tidiness: MSVC puts a
// member's access in its mangled name, so two views that disagreed would
// not link on Windows.
//
// And it works in each view: the importer (Inputs/access_cxx_view/app.k)
// and the C++ host (host.cpp) instantiate vault.k's generic function and
// inline its inline one in their own TUs, where Vault's friend lines grant
// them its private members; the host itself sees those members private
// (its static_asserts), and naming one is clang's error in the host's own
// file, not an internal one.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/access_cxx_view && %kairo vault.k -c -o %t.d/vault.o --cache-dir %t.d/c1 --print-ir 2>/dev/null > %t.d/own.ir
// RUN: tr -d '[:space:]' < %t.d/own.ir | %FileCheck %s --check-prefix=VIEW
// RUN: cd %S/Inputs/access_cxx_view && %kairo app.k -c -o %t.d/app.o --cache-dir %t.d/c2 --print-ir 2>/dev/null > %t.d/app.ir
// RUN: tr -d '[:space:]' < %t.d/app.ir | %FileCheck %s --check-prefix=VIEW
// RUN: cd %S/Inputs/access_cxx_view && %kairo vault.k --type-check-only --emit-headers %t.d/h
// RUN: cat %t.d/h/*.hh | tr -d '[:space:]' | %FileCheck %s --check-prefix=VIEW
// RUN: cd %S/Inputs/access_cxx_view && %kcc -E host.cpp -o %t.d/host.ii
// RUN: tr -d '[:space:]' < %t.d/host.ii | %FileCheck %s --check-prefix=VIEW
//
// The class, whitespace removed (each view renders its own): the access
// levels, then the friend lines naming every function of vault.k.
// VIEW: classVault{signedintsecret=7;protected:signedintshared=11;public:Vault()noexcept;private:Vault(signedints)noexcept;signedintpeek()constnoexcept;public:signedintopen()constnoexcept;friendsignedinthelper(::vault::Vault*v)noexcept;friendsignedintinline_read(::vault::Vault*v)noexcept;template<classT>friendsignedintgen_read(::vault::Vault*v,Tt)noexcept;friend::vault::Vaultmake(signedints)noexcept;};
//
// RUN: cd %S/Inputs/access_cxx_view && %kairo app.k -o %t.d/app --cache-dir %t.d/c3
// RUN: %t.d/app
// RUN: cd %S/Inputs/access_cxx_view && %kcc host.cpp -o %t.d/host
// RUN: %t.d/host
// RUN: cd %S/Inputs/access_cxx_view && { %kcc -DPOKE -c host.cpp -o %t.d/poke.o 2>&1 || true; } | %FileCheck %s --check-prefix=POKE
// POKE: host.cpp:{{[0-9]+}}:{{[0-9]+}}: error
// POKE-SAME: 'secret' is a private member of 'vault::Vault'
// POKE-NOT: I003E
