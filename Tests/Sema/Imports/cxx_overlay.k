// rule: `cxx::std` is C++'s `std`; bare `std` is kairo's. The overlay is a
// TRANSPARENT alias -- the declarations it reaches are the header TUs' own,
// they keep their own paths, and codegen spells them `::std::…` exactly as it
// did when bare `std` reached them. `cxx` exists for one reason: bare `std`
// now means `kairo::std`.
//
// `cxx` binds only in a TU with an ffi import, has exactly one member, and is
// not a general prefix: every other top-level C++ name still folds bare, so
// `boost::`, `absl::` and friends are untouched.

ffi "c++" import "<string>"

fn from_cxx() -> void {
    var s: cxx::std::string
}

fn from_kairo() -> void {
    std::print(3)
}

fn cxx_alone() -> void {
    var bad: cxx
}

// --- lit wiring -----------------------------------------------------------
//
// 1. `cxx` used alone is diagnosed, and it is the ONLY diagnostic in the file:
//    the header type resolved, and so did kairo's std.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: R053E
// DIAG-SAME: cxx::std
// DIAG-NOT: {{error|warning}} [
//
// 2. the alias never reaches codegen. `cxx::std::string` is emitted as
//    `::std::string` -- if `cxx` appeared in the emitted C++ the alias would
//    not be transparent -- and kairo's own std keeps its `kairo` prefix.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: cxx
// CXX-DAG: std
// CXX-DAG: kairo
