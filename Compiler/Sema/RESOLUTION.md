# Symbol tables & the resolution pipeline

Design doc for the TU symbol table and the ordering contract between
ImportResolution, NameResolution, TypeResolution, and ChainBinding. This is
the third and only REAL symbol table in the compiler. The other two are
phase artifacts and stay untouched: DisambigTable answers one boolean for
the parser pre-parse; the macro table belongs to the PP.

Companion: IMPORTS.md (the import forms, the overlay, and how resolved
links become emitted C++). Where this doc and IMPORTS.md overlap, IMPORTS.md
is authoritative for anything touching an `ImportDecl`.

Status legend:

    [DONE]      implemented, tested against `--print-sema`
    [PARTIAL]   implemented for a stated subset; the gap is named
    [BROKEN]    implemented, wrong; the fix is specified
    [MISSING]   not implemented; owner and shape are specified
    [DECIDED]   a rule with no code behind it yet; do not relitigate

---

## 1. Symbol table data structure [DONE]

Principle: **the AST is the trie; tables are per-DeclContext leaf maps.**
No parallel scope tree. DisambigTable's mirror-trie needed `_wire_scopes`
to reconcile two structures; this design has nothing to reconcile.

`AST/Context/SymbolTable.k` (DeclName, OverloadCell, SymbolTable), wired
into `DeclContext::dc_symbols` + `TranslationUnit::{out_of_line,
import_overlay}`, populated by `ASTParse::_build_symbols`.

```
class SymbolTable {                    // one per DeclContext (TU, module, type)
    var cells:  map<u64, OverloadCell> // key: DeclName::as_key()
    var frozen: bool = false
    fn append(name: DeclName, d: *Decl)  // parse-time only; asserts !frozen
    fn lookup(name: DeclName) -> *OverloadCell
    fn freeze(self)
}

// DeclName = kind:u8 + payload:u32, packed to u64:
//   Identifier(imm)   payload = this TU's imm ident index
//   Operator(k0,k1)   payload = packed op-token kinds (stable cross-TU)
//   Constructor       payload = 0; CONTEXT-RELATIVE
//   Destructor        reserved; `fn op delete` keys as Operator for now.
// Names stay pure name-domain: constructing a DeclName never needs type
// info.
```

- **Keys** are per-TU `u32` imms. Cross-TU keys never mix (invariant #2).
  Operator keys pack TokenKinds, build-stable, so ADL may compare them
  cross-TU.
- **Builtins are NOT names.** `i32` lexes as `AtI32`, a keyword token, and
  never enters a table. It is a universal entity: a `BuiltinType`
  singleton in the canonical store, resolved by token kind in T (§2.6).
  A user decl cannot shadow it. The old WellKnownType rows for primitives
  were permanently `<unresolved>` for this reason and are gone.
- **Extension members** land in the ExtensionDecl's OWN table. Folding
  them into the target type's lookup is MemberLookup's job (§2b) [DONE];
  rewriting `semantic_dc` is ExtensionLowering's [MISSING].
- **Enum variants** keyed into the enum's table by the build walk.
- **Dual-context links**: `lexical_dc` / `semantic_dc` on every indexed
  decl. Out-of-line defs get `semantic_dc = null` until N(a) attaches.
- **Qualified lookup** walks `decl -> dc_symbols` per segment.
- **Unqualified lookup**: this DC's table -> DC parent chain -> overlay
  -> miss.
- **Anonymous scopes** get no table; decls land in the enclosing DC's.
- **Excluded**: locals and params (N's lexical stack); generic params
  (T's frame stack). Neither is in any table by design.

### Population (parser-owned) [DONE]

`ASTParse::_build_symbols()` at the end of `parse()`. Append-only,
zero diagnostics, zero judgment; `fn Class::method` to `out_of_line`;
freeze every table at exit. One walk, one place to audit.

---

## 1b. Canonical types [DONE]

`AST/Context/CanonicalTypes.k` + `AST/Node/CanonicalNodes.k`.

`Type::canonical` is a pointer, and pointers only compare inside one
uniquing domain. Kairo has one ASTContext per fid, so a per-fid store
would make `a->canonical == b->canonical` false the moment two TUs both
write `i32`. Monomorphization and the instantiation registry key on that
identity. Therefore:

- **One `CanonicalTypeStore` per BUILD**, owned by `GlobalDisambigTable`,
  reached via `SemaContext::types`. Mutex-guarded (P/N/T are per-TU
  parallel). Own arena, so canonicals outlive any fid's `ast_alloc` reset.
- **Two node kinds the parser never produces:** `BuiltinType` (one
  singleton per `BuiltinKind`, self-canonical, sizes from the target's
  pointer width for usize/isize) and `RecordType(decl, canonical args)`
  the canonical form of every nominal type use. `Foo`, `ns::Foo`, an
  imported `Foo`, and `Alias` all canonicalize to the same `RecordType`.
- **Uniqued on structure, quals excluded** (Base.k invariant): pointer,
  nullable, vector, set, map, tuple, fixed array (known extent only),
  function pointer, generic param (on `(owner decl, index)`, never on the
  name), opaque FFI (on spelling imm).
- **Contract:** callers pass ALREADY-CANONICAL components. T resolves
  bottom-up (post-order `dispatch_type` override) so this is never
  violated.

`GenericParamType` gained an `owner: *Decl` field for the uniquing key.
`TypeKind` gained `RecordType` and `BuiltinType`; the RAV treats both as
leaves (their components are shared build-wide and must not be re-walked
per referring TU).

---

## 1c. Resolution state [DONE]

`Sema/Resolve/ResolutionState.k`. Per-TU side table on `SemaContext`:
`Unresolved | InProgress | Resolved | Errored` per decl and per type node,
plus the active resolution stack. `InProgress` is the load-bearing state:
re-entering it is a cycle in the USER's program, reported with the stack
as notes. `Errored` is permanent, so a bad alias used fifty times reports
once.

A side table, not a field on Decl: `ast_alloc` is reset per stage, a
SemaContext is per-TU-per-run (LSP re-runs start clean), and Decl already
has `poisoned` a second "done" bit that can disagree with the first is
a second source of truth.

Diagnoses NOTHING itself (leaf component, AST + Location imports only).
The pass that hits the cycle owns the message.

---

## 2. Pipeline order and invariants

```
P:  parse (per TU, parallel)            -> AST + frozen SymbolTables     [DONE]
I:  ImportResolution (DAG order)        -> import_overlay built          [DONE]
E:  Expand (requires-desugar, macros)   -> canonical syntax              [PARTIAL: desugar only]
V:  Verify (structural checks)          -> pure reads                    [DONE]
N:  NameResolution (per TU, parallel)   -> every HEAD bound              [DONE]
T:  TypeResolution (per TU, DAG order)  -> every Type node canonical     [DONE]
    ChainBinding (same stage, after T)  -> every decidable STEP bound    [DONE]
C:  checks                              -> shape/conformance/access      [MISSING]
L:  lowerings                           -> codegen-shaped tree           [MISSING]
M1: instantiation registry (parallel)                                    [MISSING]
M2: instantiate + dependent conformance (sync)                           [MISSING]
```

**Ordering is DAG order, not just parallel.** `CompilerInstance::_sema`
runs each fid's pipeline in reverse import-tree order. I needs it (source
overlay complete before re-export folds). T needs it (an imported file's
Type nodes are canonical before an importer expands an alias through them
— T WRITES `canonical` onto nodes in another fid's arena, and DAG order is
what makes that a single write on a single thread). Invariant #4's "T is
embarrassingly parallel" is therefore parallel ACROSS independent subtrees
only. Do not change the loop order.

### 2.1 P parse [DONE]

POST: every DC has a frozen table; `out_of_line` collected.
INVARIANT: frozen tables are never mutated again by ANY later phase.

### 2.2 I ImportResolution [DONE, IMPORTS.md §4]

The decided contract from the previous revision of this doc stands
unchanged and is now maintained in IMPORTS.md §2.3 and §4. Summary:
path->fid is the PP's; keys re-intern once at the boundary; overlay cells
are thin and multi-target; plain imports bind ONE name (the ModuleDecl);
import everything, carry the visibility fact, diagnose at use; two walls
against accidental transitivity; parse-time disambig is lazy; NO unfold
pass, NO fwd-decl synthesis, NO textual rewrite.

Known defects, all specified with fixes in IMPORTS.md: ModuleHandle and
FfiAnchor excluded from `merged` (plain imports resolve to an empty cell);
reopened namespaces flagged ambiguous; symbol-path imports
(`import foo::X`) fold as module handles; re-export unimplemented.

### 2.3 E Expand [PARTIAL]

`RequiresDesugar` runs. Macro expansion and eval lowering do not. Needs
nothing past Parsed; sits after I only because the schedule is linear.

### 2.4 V Verify [DONE]

Six independent structural checks. Errors hard-stop before N.

### 2.5 N NameResolution [DONE]

`Sema/Resolve/NameResolution.k`. Two halves, one pass.

(a) Decl validation over frozen cells: link `Redeclarable` chains for the
five type kinds + modules, retarget canonical at the definition, diagnose
redefinition and conflicting kinds, attach `out_of_line` defs
(`semantic_dc` := owning type's context), populate `sc.well_known`
(library lang items only; primitives are builtins, §1).

    [MISSING] FUNCTION redecl chains: telling a redeclaration from an
    overload needs signatures. Deferred to OverloadResolution. Out-of-line
    defs are ATTACHED but not linked into the in-class decl's chain for
    the same reason.

(b) Binding: every `NamedIdentExpr` head gets `resolved_decl` (unique) or
`candidate_cell` (a cell it never filters invariant #3). Order: lexical
locals stack (innermost frame first; params and generic params of the
enclosing FUNCTION live in its frame) -> `sc->lookup.unqualified(cur_dc)`
-> miss. Redecl chains collapse to the canonical; a genuine overload set
goes through whole. Statement binders (`for`, `catch`, destructuring,
`case var n`, context bindings) declare into the lexical stack; the
value/iterable is resolved in the OUTER scope first, so `for x in x`
names an outer `x`. Attribute names bind when a decl exists, silently
otherwise. Import-access ("exists but private") is emitted here.

    [DONE] A type scope's generic params are in the lexical stack.
    `traverse_class_decl` and its struct/union/interface/enum/extension/
    alias siblings push a locals frame holding `n->generic_params`
    (`_open_type_generics` / `_close_type_generics`), exactly as
    `traverse_function_decl` does, so `T` in EXPRESSION position inside
    the body a `requires T impl X` on the class, a `ConstraintExpr`
    lhs, `T::CONST` binds. The frame is pushed only when the decl
    actually has generic params, so a non-generic type costs neither a
    frame nor an empty trace scope. Test:
    Tests/Sema/typeres_class_generic_expr.k.

    [DONE, TEMPORARY] The bare-ffi miss gate. A bare
    `ffi "c++" import "h.hh"` puts the header's names in unqualified
    scope, but those declarations exist only inside clang until the
    extraction pass, so an unqualified miss in a TU that carries one is
    left unbound and marked foreign (`NamedIdentExpr::foreign`,
    `TraceRow::foreign_gate`, skipped by NameBindingVerifier) instead of
    diagnosed. Nothing is poisoned, so T treats the node as absent rather
    than errored. This turns typos in such a TU into deferred clang
    errors, which is why it is gated on the presence of a bare ffi import
    in THIS TU and why extraction DELETES it rather than improving it.
    IMPORTS.md §5.

    [DONE, by design] N does NOT bind: chain steps (ChainBinding, §2.7);
    ConstructorPattern / UnresolvedConstructorPattern HEADS and bare
    `case n` (need the scrutinee type; pattern checking owns them);
    named-initializer field names (`Point { x: 1 }` `InitField.name`
    is a bare token; inference owns it); attribute ARGUMENTS.

`NameBindingVerifier` is N's exit test: no reachable `NamedIdentExpr`
survives with both slots null unless poisoned. Reports through the diag
sink, not assert (release builds compile asserts out).

### 2.6 T TypeResolution [DONE]

`Sema/Resolve/TypeResolve.k`. Every type node gets `canonical`,
`type_flags`, and per-segment `resolved_decl` / `resolved_type`. Poisons
on error.

**T never rewrites a node.** `T` inside `fn foo<T>()` stays a `ChainType`
whose canonical is a `GenericParamType`. Rewriting kinds through a RAV is
unsafe (the parent holds the old pointer type) and buys nothing: every
consumer reads `->canonical`.

**Post-order, demand-driven.** `dispatch_type` is overridden: children
first, then `resolve(node)`, memoized on ResolutionState. Aliases expand on
demand through `_expand_alias`, which claims the alias decl before
descending `type A = B; type B = A` is one error with every link as a
note, not a hang. This is the interleaving RESOLUTION.md's previous
revision said "may be fused later": the cycle that needs it is
alias<->lookup INSIDE T, and that is where it lives. N and T remain
separate passes.

What T decides:
- **Builtins** by token kind of the first segment, before any lookup.
  `i32::x` and `i32<T>` are errors here.
- **Heads**: generic frames (innermost first; a method's `<T>` shadows its
  class's) -> `sc->lookup.unqualified(cur_dc)`. Redecl chains collapse to
  the canonical; a cell with both a type and a value under one name picks
  the type (the redefinition was N(a)'s error).
- **`::` segments** step through `context_of(decl)`, expanding an alias
  first. `T::Item` and `Foo<T>::Inner` are marked Dependent and stopped
  (invariant #5); M2 owns member-of-instantiation.
- **Final decl -> canonical**: `GenericParamDecl` -> `generic_param(owner,
  index)`, dependent (const params in type position: error).
  `TypeAliasDecl` -> expand; a GENERIC alias applied with args is arity-
  checked then marked instantiation-dependent substitution is M2's.
  Nominal types -> arity check against the primary (required = params
  with no default and not a pack; packs unbound above) -> args placed by
  position and by name (unknown name, duplicate name: errors) -> defaults
  resolved in the primary's scope on demand -> `record(canon, args)`.
  `ModuleDecl` in type position: error.
- **Structural kinds** read their components' canonicals and ask the
  store. `[T; N]` canonicalizes only for a literal N; otherwise
  instantiation-dependent (the evaluator owns it; `const N` is legal and
  not decidable here). `[T;]` is extent 0 with `is_incomplete` on the
  syntax node. Unprototyped `fn()` canonicalizes as zero-param.
- **`Self` / `self`-in-type-position** -> the innermost type scope's
  record with its OWN params as args (dependent for a generic type).
- **Receiver synthesis.** `ParamDecl::create_self` leaves `type_` null. T
  is the one writer: a `SelfType` node with the enclosing record as
  canonical. This is what lets ChainBinding bind `self.x` from a declared
  type instead of asking inference.
- **#68 refinement.** A `Primary`-classified spec whose head bound params
  and whose args all resolve to those params stays Primary; any concrete
  arg downgrades to Explicit. `<> Box<T>` (no head params) pre-marks its
  spec args resolved-and-dependent so `T` is never looked up.
- **Enum underlying** must be a builtin integer.
- **`extend` target** resolved first with the extension's params in frame,
  then becomes Self for the body; a non-record target is an error unless
  dependent.

Error homes (all `R001E` until the diag table is split; grep
`FIXME(diag-table)`): unknown type name, primitive with members/args,
`self` outside a type body, generic param with args, value param as type,
module as type, non-generic alias with args, arity, unknown/duplicate
named arg, alias cycle, alias depth, `::` after a non-scope, no such type
in scope, `extend` on a non-type.

    [PARTIAL] `_pick_type_candidate` collapses same-name type decls to
    "first entity". Explicit/partial SPECIALIZATIONS are distinct decls
    under one name; lookup picks the primary. Correct for name lookup,
    insufficient for M2, which needs the specialization set. Home: the
    instantiation registry.

    [PARTIAL] Default types on an IMPORTED primary resolve in the
    importer's scope; `_collect_args` should thread the primary decl into
    `_demand_in_scope_of`. Exercise with a test before fixing.

### 2.7 ChainBinding [DONE]

`Sema/Resolve/ChainBinding.k`, scheduled inside the T stage after
TypeResolution. Walks every `ChainExpr` left to right from an ANCHOR (what
the previous step denotes) and binds each step:

    Module   -> `::` does table lookup; `.` is an error
    Type     -> `::` does member lookup (statics, nested, variants, ctors);
                `.` is an error ("use ::")
    Value    -> `.`/`->`/`?.`/`?->` peel the separator's wrapper (pointer
                for `->`, nullable / Null<T> lang item for `?.`; `.` on a
                pointer is an error) then member lookup on the canonical;
                `::` is an error
    NeedsInference / Dependent / Errored -> record why, stop the chain

Anchors come from N's head binding + T's canonical: a param/field/typed
var gives Value; a class/struct/enum/interface/alias gives Type; a module
gives Module; a generic param gives Dependent; a call, an inferred `var`,
an overload set, a function value, or an operator/tuple-index step gives
NeedsInference. After binding a field the next anchor is the field's type;
after a function it is NeedsInference (a call result).

Commit rule: one decl -> `resolved_decl`; all functions -> `candidate_cell`
(the frozen cell when it IS the set, a sema-owned merged cell in
`sema_alloc` otherwise); distinct non-function entities under one name
reached through different bases -> ambiguity error with every candidate
noted. A redecl chain (fwd + def) collapses to one entity first.

Outcomes are recorded per step location in `ResolutionTrace::member_results`
and joined onto N's Member rows by SemaDump, so the scopes section reads
in source order and says what happened to each step.

    [DONE] Reopened namespaces. `Anchor.scopes` is a vector: an
    all-`ModuleDecl` candidate cell is ONE namespace spread over N
    scopes, not an overload set, and a `::` step searches every one of
    them and unions the hits. A frozen source cell is reused only when a
    single scope answered. IMPORTS.md §4.3.
    [DONE] `AnchorKind::Foreign` for ffi. Entered from an `ImportDecl`
    with ffi linkage; absorbing, so every later step records
    `MemberOutcome::Foreign` with no decl, no poison and no diagnostic.
    IMPORTS.md §5.

    [DONE] Cross-TU probes are spelled, not imm-keyed. A DeclContext's
    table is keyed by ITS OWN TU's imms (hard invariant #2), so probing a
    foreign scope with this TU's imm index is not a miss it is a silent
    wrong answer whenever the two interners happen to agree on an index.
    `MemberLookup::in_scope` re-interns the name into the owning TU's imm
    space for a foreign scope; `MemberLookup::lookup` spells the name once
    per lookup because the walk can cross several TUs (a base class in one
    file, an extension in another). Operator and ctor keys are built from
    TokenKinds and stay cross-TU safe, so they skip the translation.
    Anything that RENDERS a foreign decl has the same problem and the same
    answer: `NameLookup::ctx_of` says where a decl's names live, and the
    sema dump renderers and ChainBinding's diagnostics ask it first.

### 2.8 C checks [MISSING]

`ConstraintExtraction` runs. `OperatorSignatureCheck`, `ConformanceChecking`,
`ConstChecking`, `AccessCheck`, `TypeCycleCheck` are stubs. TypeCycleCheck
is the first to write: EmitPlan's tier-1 sort depends on it.

### 2.9 L, M1, M2 [MISSING]

See IMPORTS.md §6–7 for the codegen contract these feed. The mono model is
"Kairo enumerates and checks; C++ instantiates explicitly" M1 is the
`(template, canonical args) -> home fid` registry, M2 is the sync point
that closes it and runs dependent conformance.

---

## 2b. Member lookup & OOP

**Name hiding: MERGE, not hide (Java/C#-style, NOT C++).** [DONE]
`Sema/Resolve/MemberLookup.k`. `lookup(canonical, name, out)` walks own
table -> extensions -> bases (class `derives_list` + `implements`, struct
`implements`, interface `derives_list`) breadth-first, dedups across
virtual bases by decl identity, and returns the UNION. A derived `m(k)`
and a base `m()` are two candidates, not a hidden one. Tested: `self.m()`
in Derived yields both.

**Extensions** [DONE]: index built once per run over every parsed TU
(safe under DAG order). Records keyed by decl (so `extend <T> Vec<T>`
contributes to every `Vec<X>` at name level; which body runs is
dispatch); non-records keyed by canonical pointer (`extend i32 { }`).

**Consequence for C++ codegen** `needs_using` [MISSING]. The slot does
not exist on the type decls. When it does, the one writer is
`MemberLookup::_walk_record` at the point a base cell is unioned without
the derived type overriding it. The one consumer is `UsingDeclSynthesis`
(lowering). Codegen stays a dumb walker.

**Virtual dispatch is NOT a lookup problem.** Unchanged, [MISSING].

**Access control is a late FILTER, never a lookup key.** Unchanged;
`AccessCheck.k` [MISSING]. Lookup currently finds private members and
nothing rejects them.

**Base-walk PRE: T complete.** Now enforced by schedule: ChainBinding
runs after TypeResolution in the same stage.

---

## 3. Hard invariants

1. **Frozen means frozen.** Post-parse, source tables take no inserts.
2. **One key space per TU.** Cross-TU goes through the spell->imm shim in
   I, once per imported name.
3. **One error, one home.** Import existence/ambiguity: I. Import access:
   N(b). Redefinition / spec-without-primary: N(a). Unresolved head: N(b).
   Unknown type / arity / alias cycle / primitive misuse: T. No member /
   wrong separator / member ambiguity: ChainBinding. Dependent
   conformance: M2. Access: AccessCheck. No phase re-checks another's
   territory.
4. **Parallelism boundary.** P is parallel. I, T are DAG-ordered and
   parallel only across independent subtrees. N and M1 are per-TU
   parallel. M2 is the only sync point. The canonical store is the one
   shared mutable structure and it is locked.
5. **Dependent = deferred, not failed.** Marked and skipped by N/T/CB;
   M2 owns it.
6. **Tracing never changes behavior.** `sc->trace` is write-only for the
   compiler. ChainBinding's `member_results` is the same kind of thing:
   written for the dump, read by nothing else.
7. **One writer per fact.** `resolved_decl`/`candidate_cell` on heads: N.
   On steps: ChainBinding. Promotion cell->decl: inference. `canonical`,
   `type_flags`, segment slots, `ParamDecl::type_` for `self`: T.
   `spec_kind` refinement: T. `needs_using`: MemberLookup. A fact recomputed
   in two places drifts.
8. **Canonical identity is build-wide.** One store, one arena, one lock.
   `a->canonical == b->canonical` is type identity everywhere or nowhere.
9. **T never rewrites nodes.** Slots only.
10. **Builtins are not names.** Resolved by token kind; unshadowable; in
    no table; no lang-item row.
11. **Imports are erased at N/CB.** No later pass reads an `ImportDecl`
    except for ffi anchors and the `#include` list. (IMPORTS.md #8.)

---

## 4. What remains, in the order it should be done

Sema, name/type domain:

    a. N: class-level generic params into the lexical stack       DONE
    b. IMPORTS.md §8 items 1–9 (symbol paths, merged cell,
       reopening, foreign anchor, bare-ffi gate, re-export,
       named roots)                                              DONE
    c. `_representative` exists in N, T, and CB move to
       NameLookup as a static                                    cleanup
    d. Split R001E; grep FIXME(diag-table)                         diag table

Name resolution and import lookup are complete: every form in
IMPORTS.md §1 binds, checked end to end by
Tests/Sema/imports_all_forms. What is left in the name domain is (c),
a refactor, and (d), the diagnostic table.

Sema, type domain (each unblocks the next):

    e. OverloadResolution     clears every `Candidates` step; needed by
                                function redecl chains, ctor selection,
                                operator overloads (with ADL), UFCS
    f. TypeInference          clears every `NeedsInference` step, inferred
                                vars, tuple index, initializer field names
    g. Pattern checking       constructor-pattern heads, bare `case n`,
                                `.Variant`
    h. AccessCheck            private/protected members, protected imports
    i. ConformanceChecking    interface requirements, base validity
    j. TypeCycleCheck         by-value containment cycles; EmitPlan needs it
    k. ExtensionLowering      `semantic_dc` rewrite; interface emission
                                needs extension methods folded into the
                                class's declaration list

Codegen (IMPORTS.md §6–7):

    l. EmitPlan, out-of-line body rule, instantiation registry,
       EmitCXXHeader, clang extraction.

Everything in (a)–(d) is name-domain and is what "name resolution
complete" means. Everything from (e) on needs a type on an EXPRESSION
before a name can be picked, and is not name resolution.