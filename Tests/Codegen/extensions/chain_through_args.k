// Tests/Codegen/extensions/chain_through_args.k -- no diagnostics; every step bound
struct <T> Box  { var v: T; }
struct <T> Wrap { var inner: T; }

fn <U> peek(w: Wrap<Box<U>>) -> U { return w.inner.v; }

// --- lit wiring -----------------------------------------------------------
// Each field step reads through the receiver's args: `w.inner` is Box<U>
// (not Wrap's bare T), so `.v` binds on Box and the chain is typed U. Before
// that, `.v` was R051E ("'T' has no members").

// RUN: %kairo %s --type-check-only
// RUN: %kairo %s --type-check-only --print-sema | %FileCheck %s --check-prefix=SEMA

// SEMA:      -- name bindings --
// SEMA:      <tu>::peek
// SEMA-NEXT:   w           @ 5:44     -> param w @ 5:13
// SEMA-NEXT:   .inner      @ 5:46     -> field inner @ 3:19
// SEMA-NEXT:   .v          @ 5:52     -> field v @ 2:19
// SEMA:      -- expression types --
// SEMA:      <tu>::peek
// SEMA-NEXT:   ChainExpr               @ 5:44     : U
// SEMA-NEXT:   NamedIdentExpr          @ 5:44     : Wrap<Box<U>>
// SEMA-NEXT:   2 typed, 0 unknown, 0 errored
