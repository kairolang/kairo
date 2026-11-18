// --- lit wiring -----------------------------------------------------------
// From inside lib's module, a selective import takes fx through
// lib/a.k's `prot import` (lib/sel_in.k).
// RUN: cd %S && %kairo lib/sel_in.k --type-check-only
