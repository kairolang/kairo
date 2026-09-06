// CASE 10b: `ffi ... import "h" as z` binds `z` to an ANCHOR -- overlay key
// `legacy` with one ffi-anchor target -- that the future clang-extraction
// pass will hang real (translated) decls off of.
//
// Wired: the PP builds the ImportDecl and records it in tu->imports (no path
// resolution, no fid, no import edge, no clang), phase I binds the anchor,
// and ChainBinding gives it AnchorKind::Foreign so every step off `legacy` is
// recorded Foreign -- no decl, no poison, no diagnostic. IMPORTS.md §5.
//
// Still MISSING, and the reason a step has no decl yet: the extraction pass.
// The design is one clang parse of the header at INDEX time, ASTUnit cached
// per header, reused three ways -- (1) a cheap name+scope walk into the
// disambig table so `<`-disambiguation sees header symbols during full parse,
// (2) sema's symbol build translating clang decls into Kairo nodes off the
// anchor, (3) the backend taking the cached ASTUnit instead of reparsing via
// -include. The PARSER cannot own this: it runs after disambig decisions, too
// late to feed header symbols into `<`-disambiguation.

ffi "c" import "legacy.h" as legacy

fn use_ffi_aliased() -> i32 {
    return 0
}
