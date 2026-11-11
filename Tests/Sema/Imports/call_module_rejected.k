// `import A::B::both`, with both A/B/both.k and a `both` declared in
// A/B.k, names the MODULE (imports.mdx, "Resolution with `::`": the module
// path is tried first). Calling it is rejected by Sema, not left to fail in codegen
// (CL001E "no member named '_'").
// The braced form names the declaration and stays clean.

// --- lit wiring ---
// RUN: { %kairo %S/Inputs/call_module/use_bare.k -I %S/Inputs/call_module --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BARE
// RUN: %kairo %S/Inputs/call_module/use_braced.k -I %S/Inputs/call_module --type-check-only 2>&1 | %FileCheck %s --check-prefix=BRACED --allow-empty
// BARE: use_bare.k:4:12: error [SC001E]: 'both' is a module, not a function
// BARE: both.k:1:1: note [I900N]: 'both' is this module: where a module and a declaration share a name, an import path names the module and a braced import (`::{both}`) names the declaration
// BRACED-NOT: error
