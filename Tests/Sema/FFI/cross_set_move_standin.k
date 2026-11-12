// With -fno-shared-header-set each file's C++ headers are their own
// set. user.k imports only <utility> and calls `cxx::std::move` on an Ar,
// a Kairo class in m/Ar.k holding `unsafe *z::Blk` from blk.h, which only
// m/Ar.k imports. Ar is spelled in <utility>'s set by its stand-in, whose
// field has no spelling there: the field's fallback (a `void *`, a sized
// blob) was taken through the asker's allow_opaque_args, and that marked
// the ARGUMENT opaque, so the substituted return type was dropped and the
// call kept the declared `remove_reference_t<_Tp>&&` (SC028E "cannot
// convert ... to 'Ar'"). A stand-in's fields and bases are spelled for layout only.
//
// The default (one shared set) path never hit it and is checked too.
//
// Inputs/cross_set_move: user.k, m/Ar.k, blk.h.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/cross_set_move && { %kairo user.k -I . --type-check-only -fno-shared-header-set 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: cd %S/Inputs/cross_set_move && { %kairo user.k -I . --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [
