// A qualified macro call resolves its head the way Sema resolves the head of
// a qualified name (RESOLUTION.md §2.5): the scopes lexically around the
// call -- this file's own module blocks, then the file -- for what THIS file
// declared, then the path as written, which reaches what the file imported.
//
// Inputs/qualified_macro: L/b.k imports library `c` (c/module.k pins it)
// and calls `c::m!()` and `c::g()`. L/module.k, b.k's parent module, has a
// block `module c { }` with an `m!` and a `g` of its own, registered under
// `L::c`; b.k does not import it and Sema never binds `c` to it. The macro
// lookup tried every prefix of b.k's module path, `L::b::c` then `L::c`,
// before the path as written, and expanded L::c's `2` -- into a `bool` --
// while Sema bound `c::g()` in the same file to the library. scope_isolation.k
// is the other half: a file's own `module std { macro }` blocks are found
// first, imported or not.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/qualified_macro && %kairo main.k --type-check-only
