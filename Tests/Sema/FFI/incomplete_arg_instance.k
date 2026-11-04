// G94: a by-value record whose field is `DenseMap<Fwd, int>` (Fwd only
// declared) made the fill of DenseMapBase's member type
// `DenseMapPair<Fwd, int>` a hard libc++ error (CL001E, `pair` field of
// incomplete type) that nothing asked for: ASTContext.h's
// `DenseMap<GlobalDecl, StringSet<>>`. An instance with an incomplete class
// argument is now attempted silently and left unfilled.
// CHECK-NOT: error
ffi "c++" import "incomplete_arg_instance.h"

pub fn f() -> i32 { var c = ns::mk(); return c.x }

// --- lit wiring ---
// RUN: { %kairo %s -I %S --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --allow-empty
