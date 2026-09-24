// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only -- multiple-inheritance-specific
// subobject language dropped, see below):
//   Lib/llvm-runtimes/clang/test/SemaCXX/member-name-lookup.cpp (the
//   single-base, unambiguous half: `d.a` reaching a base field through
//   one derivation step, `D::test_lookup` reaching it unqualified from
//   inside a derived method)
//   Lib/llvm-runtimes/clang/test/CXX/class.derived/class.member.lookup/
//
// Kairo's inheritance model is Java/C#-style MERGE, explicitly NOT C++
// hiding: RESOLUTION.md §2b, "Name hiding: MERGE, not hide... A derived
// `m(k)` and a base `m()` are two candidates, not a hidden one." This is
// the OPPOSITE of what most of member-name-lookup.cpp exists to check (C++
// hides a base member entirely once the derived class declares ANY member
// of that name, independent of signature) -- so this file proves the
// Kairo-specific positive shape instead: a derived override does not hide
// the base overload; both remain reachable and both survive to (deferred)
// overload resolution.
//
// Also ported: `extend`-added members fold into member lookup for every
// value of the extended type AND every derived type (RESOLUTION.md §2b:
// "Extensions... Records keyed by decl... base `extend`s inherited too"),
// which has no clang analogue at all (C++ has no retroactive
// non-intrusive extension mechanism) but is exercised here because it is
// squarely "member lookup" and squarely Kairo's own design.
//
// Dropped: multiple-base ambiguity (`d.c` "found in multiple base classes
// of different types") -- that is member_ambiguity.k's job, kept separate
// since it is really a DIFFERENT outcome (ambiguity error) from this
// file's "everything resolves, possibly to several candidates" story;
// virtual-base subobject dedup (no virtual inheritance concept surfaced
// at this layer beyond "dedup across virtual bases by decl identity",
// which needs a diamond to exercise -- see member_ambiguity.k); static
// member "okay, no ambiguity" special-casing (needs OverloadResolution to
// pick a static overload, [MISSING]).

class Base {
    pub {
        var b: i32;
        fn m(self) -> i32 { return self.b }
    }
}

// `derives`: Derived's OWN table gets `d` and TWO `m`s (its own plus,
// via MemberLookup's base walk, Base's) -- not one overriding the other.
class Derived derives Base {
    pub {
        var d: i32;
        fn m(self, k: i32) -> i32 { return self.b + self.d + k }

        // ---------------------------------------------------------------
        // CASE 1: from INSIDE a derived method, an unqualified base field
        // (`self.b`) and the OVERLOAD SET of `self.m` (own + inherited)
        // both resolve.
        fn check_all(self) -> i32 {
            return self.b + self.d + self.m(1)
        }
    }
}

// `extend Base { ... }` adds `ext` to Base's OWN member table.
extend Base {
    pub {
        fn ext(self) -> i32 { return self.b }
    }
}

// ---------------------------------------------------------------------------
// CASE 2: a free function holding a Base value and a Derived value. The
// extension method reaches BOTH (Derived inherits Base's extensions, same
// as any other base member); the overload set for `.m` differs by anchor
// type (Base sees 1 candidate, Derived sees 2 -- its own plus Base's).
fn free_fn(a: Base, d: Derived) -> i32 {
    return a.ext() + d.ext() + a.m() + d.m(1) + a.b + d.b + d.d
}

// --- diagnostics: everything above is legal ------------------------------
// DIAG-NOT: error
// DIAG-NOT: no member named
// DIAG-NOT: ambiguous

// --- bindings ----------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}member_base_lookup.k =====

// CASE 1: base field reached unqualified from a derived method. On a BOUND
// step the "[member of X]" tag names the type the member was DECLARED in --
// Base for `.b`, Derived for `.d` -- not the anchor the lookup started from,
// so the tag answers "where does this come from". `.m` yields BOTH candidates
// (own override + inherited base method) rather than hiding the base one; a
// candidate set has no single declaring type, so that row still tags the
// anchor.
// SEMA:      fn Derived::check_all  @
// SEMA:        member  .b  {{.*}} -> field b {{.*}}  [member of Base]
// SEMA:        member  .d  {{.*}} -> field d {{.*}}  [member of Derived]
// SEMA:        member  .m  {{.*}} -> 2 candidate(s), awaiting overload resolution

// CASE 2: extension reaches through BOTH a Base value and a Derived value;
// `.m` on the Base-typed param yields exactly the base method (1
// candidate is bound outright, not left as a deferred set), on the
// Derived-typed param it yields the 2-candidate merged set.
//
// An extension member's declaring type is the type EXTENDED (an ExtensionDecl
// has no name), so both `.ext` rows read `[member of Base]` -- reached once
// through a Base value and once through a Derived one.
// SEMA:      fn free_fn  @
// SEMA:        member  .ext  {{.*}} -> fn ext {{.*}}  [member of Base]
// SEMA:        member  .ext  {{.*}} -> fn ext {{.*}}  [member of Base]
// SEMA:        member  .m  {{.*}} -> fn m {{.*}}  [member of Base]
// SEMA:        member  .m  {{.*}} -> 2 candidate(s), awaiting overload resolution  [member of Derived]

// Nothing left unbound; the overload sets are deferred, not unresolved.
// SEMA: 0 unresolved
