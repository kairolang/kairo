// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only):
//   Lib/llvm-runtimes/clang/test/SemaCXX/member-name-lookup.cpp (the
//   multiple-base-classes ambiguity half: `struct D : B, C` reaching a
//   name declared independently in two non-virtual bases)
//
// ChainBinding's commit rule (RESOLUTION.md §2.7): "distinct non-function
// entities under one name reached through different bases -> ambiguity
// error with every candidate noted"; but "all functions -> `candidate_cell`"
// -- UNCONDITIONALLY, with no signature comparison. So the C++ split
// between "field found in multiple bases: error" and "static member found
// in multiple bases: okay" isn't quite the shape here: in Kairo, ANY
// all-FunctionDecl result (same signature, different signature, one from
// a base and one from an interface it implements) is a deferred overload
// set, never an ambiguity error -- only a genuine multiple-non-function
// clash (two fields, or a field and a nested type, etc.) is ambiguous.
// That distinction -- not fn-vs-fn signature compatibility -- is the line
// this file draws.
//
// Dropped: virtual-base subobject dedup (dedups by decl IDENTITY --
// "MemberLookup... dedups across virtual bases by decl identity" -- no
// virtual-inheritance keyword exists in Kairo to construct that shape
// with); static-member "okay, no ambiguity" special case (needs
// OverloadResolution to actually pick one, [MISSING] -- what Kairo DOES
// have today is "deferred candidate set", checked here as CASE 2, which
// is the honest analogue of "okay" pre-overload-resolution).

// ---------------------------------------------------------------------------
// CASE 1 (negative): two unrelated bases each declare a FIELD named `x`.
// Diamond-free multiple inheritance -- `derives A, B` -- makes both
// reachable from C with no common ancestor to prefer. Ambiguous: a real
// ChainBinding error, every candidate noted.

class A {
    pub { var x: i32; }
}
class B {
    pub { var x: i32; }
}
class C derives A, B {
    pub { }
}

fn use_c_field(c: C) -> i32 { return c.x }

// ---------------------------------------------------------------------------
// CASE 2 (positive): two unrelated bases each declare a FUNCTION named
// `f`, with DIFFERENT (incompatible) bodies reading different fields. This
// is NOT ambiguous -- both are FunctionDecls, so ChainBinding's `all_fn`
// path takes over unconditionally and defers to overload resolution rather
// than erroring. (Whether overload resolution could actually pick one is
// a separate, later question OverloadResolution does not exist yet to
// answer -- see RESOLUTION.md §2.5(a)'s FUNCTION-redecl-chains gap. Here
// the point is narrower: it correctly does NOT get treated as the CASE 1
// kind of clash.)

class WithF1 {
    pub { var x: i32; fn f(self) -> i32 { return self.x } }
}
class WithF2 {
    pub { var y: i32; fn f(self) -> i32 { return self.y } }
}
class Combined derives WithF1, WithF2 {
    pub { }
}

fn use_combined_fn(c: Combined) -> i32 { return c.f() }

// ---------------------------------------------------------------------------
// CASE 3 (positive): an interface's ABSTRACT method declaration and the
// implementing class's CONCRETE definition of the same name are two
// separate FunctionDecls reachable from the same anchor (the interface's
// signature is never "satisfied and removed" from lookup -- there is no
// virtual-dispatch slot-filling at this layer, RESOLUTION.md §2b: "Virtual
// dispatch is NOT a lookup problem... [MISSING]"). Also not ambiguous, for
// the same all-fn reason as CASE 2.

interface Shout {
    fn shout(self) -> i32;
}

class D derives A impl Shout {
    pub {
        fn shout(self) -> i32 { return self.x }
    }
}

fn use_d(d: D) -> i32 { return d.shout() + d.x }

// --- expected diagnostics ---------------------------------------------
// DIAG: 'x' is ambiguous: it names more than one member reachable from here
// DIAG-NEXT: note{{.*}}: candidate declared here
// DIAG-NEXT: note{{.*}}: candidate declared here
//
// CASE 2 and CASE 3 must not be flagged ambiguous.
// DIAG-NOT: 'f' is ambiguous
// DIAG-NOT: 'shout' is ambiguous
// DIAG-NOT: no member named

// --- bindings ----------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}member_ambiguity.k =====

// CASE 1: the ambiguous `.x` is poisoned, not silently dropped.
// SEMA:      fn use_c_field  @
// SEMA:        member  .x  {{.*}}<UNRESOLVED>{{.*}}(diagnosed)

// CASE 2: `.f` reaches BOTH bases' functions as a deferred set.
// SEMA:      fn use_combined_fn  @
// SEMA:        member  .f  {{.*}} -> 2 candidate(s), awaiting overload resolution

// CASE 3: `.shout` reaches BOTH the interface signature and D's own
// definition as a deferred 2-candidate set; `.x` (an ordinary inherited
// field, no interface involvement) binds outright.
// SEMA:      fn use_d  @
// SEMA:        member  .shout  {{.*}} -> 2 candidate(s), awaiting overload resolution
// SEMA:        member  .x  {{.*}} -> field x {{.*}}
