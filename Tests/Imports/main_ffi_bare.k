// CASE 10a (XFAIL  deferred to clang header-parse integration):
// bare ffi import should contribute NOTHING to the overlay.
//
// Today the PP DROPS ffi imports entirely (builds no ImportDecl), so this
// trivially shows 0 overlay keys  but for the wrong reason (dropped, not
// handled). When the clang integration lands, the real behavior is: a single
// clang parse of the header at INDEX time, ASTUnit cached per header, reused
// for (1) disambig name/scope injection, (2) Kairo symbol-table translation,
// (3) backend codegen without a cc1 -include reparse. A bare ffi import still
// yields no overlay entry, but the machinery will exist to prove it.
//
// NOTE: no semicolon (stage1 optional). The current PP drop-scan terminates
// only on `;`, so this line is a known over-consume case until the ffi rework.

ffi "c" import "legacy.h"

fn use_ffi_bare() -> i32 {
    return 0
}
