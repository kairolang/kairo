// CASE 10b (XFAIL  deferred to clang header-parse integration):
// `ffi ... import "h" as z` should bind `z` to an ANCHOR the future clang-
// extraction pass hangs real (translated) decls off of  overlay key `legacy`
// with one ffi-anchor target.
//
// NOT wired yet. The PP currently DROPS ffi imports (builds no ImportDecl), so
// nothing reaches phase I to bind the anchor  today this shows 0 overlay keys.
//
// The real design (next task): the index/PP layer, which already resolves the
// header path, calls clang ONCE, caches the ASTUnit per header, does a cheap
// name+scope walk into the disambig table, and records the ffi ImportDecl so
// phase I binds `z` as the anchor. Sema's symbol build then translates clang
// decls -> Kairo nodes off that anchor (reading the same cache), and the
// backend hands clang the cached ASTUnit instead of reparsing via -include.
// The PARSER cannot own this: it runs after disambig decisions, too late to
// feed header symbols into `<`-disambiguation. See RESOLUTION.md (clang
// extraction pass) + Preprocessor::_handle_ffi.

ffi "c" import "legacy.h" as legacy

fn use_ffi_aliased() -> i32 {
    return 0
}
