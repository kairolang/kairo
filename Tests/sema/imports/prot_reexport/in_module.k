// --- lit wiring -----------------------------------------------------------
// A `prot import` re-exports to the files of its own module. lib/sib.k
// reaches lib/x.k's fx through lib/a.k's `prot import` by every import form
// (wildcard, `a::fx`, a symbol path), and lib/chained.k reaches it through
// two `prot import`s in a row (lib/c.k of lib/a.k), all inside lib's module.
// RUN: cd %S && %kairo lib/sib.k --type-check-only
// RUN: cd %S && %kairo lib/chained.k --type-check-only
