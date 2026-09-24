// RUN: { %kairo %s 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// The NameResolution (phase N) acceptance test. Ten cases, in spec order.
//
// What this file can prove, and how:
//
//   POSITIVE cases (1, 2, 3, 4, 6, 7, 10) are proven by the ABSENCE of a
//   diagnostic at their line. Each is written so that the WRONG binding
//   produces an error: `var g = g` inside a function errors iff the
//   initializer bound to the not-yet-declared inner `g` instead of the outer
//   one, a shadowing failure errors iff the shadowed name is otherwise
//   unreachable, and so on. DIAG-NOT below pins that down.
//
//   NEGATIVE cases (5, 8, 9) assert the exact error, in source order.
//
//   WHICH decl each name bound to is asserted by the second RUN line against
//   `--print-sema`, which dumps every resolved_decl link with its target's
//   kind and location. That is what makes cases 1-4, 6, 7 and 10 real
//   assertions rather than just "no error was reported".

// CASE 6: wildcard-imported name resolves.
import nameres_lib::*
// CASE 7: selective aliased import resolves under the alias.
import nameres_lib::{selective_target as aliased}

// ---------------------------------------------------------------------------
// CASE 1: two same-name functions, different arity. Both land in one cell;
// N hands the whole cell through as candidate_cell and does NOT select.
// A cell that N wrongly treated as a redefinition would error here.

fn overloaded(a: i32) -> i32 { return a }
fn overloaded(a: i32, b: i32) -> i32 { return a }

fn use_overloaded() -> i32 {
    return overloaded(1)
}

// ---------------------------------------------------------------------------
// CASE 10: same-name class forward declaration + definition. N(a) links the
// redecl chain and repoints canonical at the definition. A chain N failed to
// recognise would surface as a redefinition error on the second `class Shape`.

class Shape;

class Shape {
    var side: i32;
}

// ---------------------------------------------------------------------------
// CASE 2: a body local shadows a file-scope name of the same spelling.
// `shadowed` exists at file scope, so a shadowing failure is silent   but the
// local is declared AFTER a use of the outer one, so getting the order wrong
// turns the first use into use-before-declare.

var shadowed: i32 = 10;

fn local_shadows_global() -> i32 {
    var before = shadowed;      // outer: the local is not declared yet
    var shadowed: i32 = 20;     // shadows from here on
    return before + shadowed
}

// ---------------------------------------------------------------------------
// CASE 3: a param shadows a field of the enclosing type. Inside the method
// body `count` must be the param, not the field.
//
// The sibling method is the other half of the same rule: with no local named
// `count` in scope, a bare `count` does NOT fall through to the field. Kairo
// has no implicit `this->` (R049, RESOLUTION.md 2.5) -- a member needs
// `self.`. That is what makes the param case above meaningful rather than
// coincidental: the param wins because it is a LOCAL, not because it beat the
// field in a contest both could enter.

class Counter {
    var count: i32;

    fn bump(self, count: i32) -> i32 {
        return count
    }

    fn field_needs_self(self) -> i32 {
        return self.count
    }
}

// ---------------------------------------------------------------------------
// CASE 4: `var x = x;` the initializer sees the OUTER scope.
// `outer_x` exists at file scope. If N declared the local before walking the
// initializer, the init would bind the not-yet-visible local and this line
// would error; it must not.

var outer_x: i32 = 5;

fn init_sees_outer() -> i32 {
    var outer_x = outer_x;
    return outer_x
}

// ---------------------------------------------------------------------------
// CASE 6/7 uses.

fn use_imports() -> i32 {
    var a = wildcard_target();
    var b = aliased();
    return a + b
}

// ---------------------------------------------------------------------------
// CASE 5: use-before-declare inside a body. `later` is declared further down
// the SAME frame, so it is not visible at the point of use, and no file-scope
// `later` exists to fall back to. Exactly one error.

fn use_before_declare() -> i32 {
    var v = later;
    var later: i32 = 1;
    return v
}

// ---------------------------------------------------------------------------
// CASE 8: undefined identifier. Exactly one error, no cascade.

fn undefined_ident() -> i32 {
    return no_such_name
}

// ---------------------------------------------------------------------------
// CASE 9: redefinition in the same frame.

fn same_frame_redefinition() -> i32 {
    var dup: i32 = 1;
    var dup: i32 = 2;
    return dup
}

// --- expected diagnostics, in source order ---------------------------------
//
// Line numbers below refer to the CODE above and are stable as long as that
// code is not edited; the check block itself sits at the end of the file so
// editing it shifts nothing. Regenerate with:
//   kairo Tests/Sema/Lookup/name_resolution.k --type-check-only --print-sema

// CASE 5
// DIAG: name_resolution.k:115:{{[0-9]+}}: error{{.*}}: use of undeclared identifier 'later'
// CASE 8
// DIAG: error{{.*}}: use of undeclared identifier 'no_such_name'
// CASE 9
// DIAG: error{{.*}}: redefinition of 'dup'
// DIAG: note{{.*}}: previous declaration of 'dup' is here

// Nothing else. In particular none of the positive cases may report:
// DIAG-NOT: undeclared identifier 'overloaded'
// DIAG-NOT: undeclared identifier 'shadowed'
// DIAG-NOT: undeclared identifier 'count'
// DIAG-NOT: undeclared identifier 'outer_x'
// DIAG-NOT: undeclared identifier 'wildcard_target'
// DIAG-NOT: undeclared identifier 'aliased'
// DIAG-NOT: redefinition of 'overloaded'
// DIAG-NOT: redefinition of 'Shape'
// DIAG-NOT: redefinition of 'shadowed'
// DIAG-NOT: redefinition of 'outer_x'

// --- resolved bindings, asserted against --print-sema ----------------------
//
// This is what makes cases 1-4, 6, 7 and 10 real assertions: each row names
// the exact decl the use bound to. Anchored on this file's own section, since
// the imported module dumps first.
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}name_resolution.k =====
// SEMA: phase: NamesResolved

// CASE 10: forward decl + definition form ONE chain, and canonical is the
// DEFINITION (line 46), not the first-seen forward decl (line 44).
// SEMA:      <tu>::Shape   [redecl chain x2]
// SEMA-NEXT:   - class Shape @ 44:1
// SEMA-NEXT:   - class Shape @ 46:1  [definition]  [canonical]

// CASE 1: both arities land in one cell, and N hands the cell through WITHOUT
// selecting -- 2 candidates survive to overload resolution.
// SEMA:      <tu>::overloaded   [overload set x2]
// SEMA-NEXT:   - fn overloaded @ 32:1
// SEMA-NEXT:   - fn overloaded @ 33:1
// The lexical-scope trace shows the same use as "deferred to overload
// resolution"; anchor on the BINDINGS row so the two SEMA-NEXTs below
// attach to the candidate list and not to that earlier line.
// SEMA:      overloaded  @ 36:12  -> 2 candidate(s), awaiting overload resolution
// SEMA-NEXT:     - fn overloaded @ 32:1
// SEMA-NEXT:     - fn overloaded @ 33:1

// CASE 2: the first use binds the FILE-scope var (56); once the local exists,
// the same spelling binds the LOCAL (60).
// SEMA:      <tu>::local_shadows_global
// SEMA-NEXT:   shadowed  @ 59:18  -> var shadowed @ 56:1
// SEMA:        shadowed  @ 61:21  -> var shadowed @ 60:5

// CASE 3: in bump the param wins, and the trace names the field it hid. In the
// sibling method the field is reached through `self`, so N binds only the
// receiver -- the `.count` step is ChainBinding's, and stays open here.
// SEMA:      <tu>::Counter::bump
// SEMA-NEXT:   count  @ 79:16  -> param count @ 78:19  [local frame 0]  (shadows field count @ 76:5 in Counter)
// SEMA:      <tu>::Counter::field_needs_self
// SEMA-NEXT:   self  @ 83:16  -> param self @ 82:25  [local frame 0]
// SEMA-NEXT:   .count  @ 83:21  <open: inference or M2>

// CASE 4: `var outer_x = outer_x` -- the initializer binds the OUTER var (87),
// and only the following use binds the local (90).
// SEMA:      <tu>::init_sees_outer
// SEMA-NEXT:   outer_x  @ 96:19  -> var outer_x @ 93:1
// SEMA-NEXT:   outer_x  @ 97:12  -> var outer_x @ 96:5

// CASE 6/7: both resolve cross-TU into nameres_lib.k, and the alias binds the
// ORIGINAL decl (selective_target), not a synthetic one.
// SEMA:      wildcard_target  @ 104:13  -> fn wildcard_target @ 7:5
// SEMA-NEXT:   aliased  @ 105:13  -> fn selective_target @ 9:5

// CASE 5 / 8: unresolved, and marked diagnosed rather than silently null.
// SEMA:      later  @ 115:13  <UNRESOLVED>  (diagnosed)
// SEMA:      no_such_name  @ 124:12  <UNRESOLVED>  (diagnosed)

// CASE 9: the redefinition loser is poisoned so downstream degrades instead
// of cascading.
// SEMA:      dup  @ 133:12  -> var dup @ 132:5  [poisoned]

// Whole-file tally: nothing unbound-and-undiagnosed.
// SEMA:      15 bound, 1 deferred (overload sets), 2 unresolved
