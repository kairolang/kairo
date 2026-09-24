// rule: a system C++ header imports like any other. `std::vector<i32>` is an
// instance of an imported class template (clang fills it), `push_back`
// takes `const T&`, `size` returns `size_t`.

ffi "c++" import "vector"

fn use_vector() -> u64 {
    var v: cxx::std::vector<i32>
    v.push_back(1)
    return v.size()
}

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// Header roots are hard-passed by lit (--sysroot / --resource-dir, see
// lit.cfg.py). `<vector>` parses and indexes, `std::vector<i32>` resolves,
// and `push_back(const T&)` deduces T through the reference.
//
// `v.size()` is the case that needs clang's instantiation: vector's
// `size_type` is spelled through `allocator_traits<...>::size_type`, a
// dependent member typedef the pattern cannot answer. The first lookup into
// `std::vector<i32>` fills the instance from clang (ForeignInstantiate), so
// size() returns canonical `unsigned long` -- u64. The function returns u64
// to match: `usize` is a distinct type and crossing to it takes `as`
// (Tests/Sema/Types/usize_distinct.k), exactly as the oracle's `unsigned long`.
//
// The bound NAMES, not just the types: the fill pins members to vector's
// forward-declaring header (<__fwd/vector.h>) while they are written in
// <__vector/vector.h>, and a name token minted in the first's interner but
// ranged in the second read back as another identifier -- `.size` bound as
// `fn cend`, `.push_back` as `fn at`, with the types still right. Header
// lines are left open: they are the host libc++'s, not this tree's.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang
//
// SEMA:      member  .size  {{.*}} -> fn size @ {{[0-9]+:[0-9]+}}  [member of vector]  [filled by clang
// SEMA:      -- name bindings --
// SEMA:      .push_back  @ 9:7 -> fn push_back @ {{[0-9]+:[0-9]+}}{{$}}
// SEMA:      .size  @ 10:14 -> fn size @ {{[0-9]+:[0-9]+}}{{$}}
