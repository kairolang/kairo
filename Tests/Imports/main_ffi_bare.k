// CASE 10a: a bare ffi import contributes NOTHING to the overlay.
//
// The PP now builds the ImportDecl (header, alias, linkage) and records it in
// tu->imports rather than dropping the tokens outright, so phase I sees it --
// and a BARE ffi import has no alias, so I binds no overlay key for it. The
// header's names still live only inside clang; what a bare import DOES change
// is what an unqualified miss means in this TU, which is N's temporary
// foreign gate (IMPORTS.md §5), tested separately.
//
// When the clang extraction pass lands, the header is parsed once at INDEX
// time and the cached ASTUnit is reused for (1) disambig name/scope
// injection, (2) Kairo symbol-table translation, (3) backend codegen without
// a cc1 -include reparse. A bare ffi import still yields no overlay entry.
//
// NOTE: no semicolon (stage1 optional). The PP's ffi scan terminates on a
// newline as well as on `;`, so this no longer over-consumes the next line.

ffi "c" import "legacy.h"

fn use_ffi_bare() -> i32 {
    return 0
}
