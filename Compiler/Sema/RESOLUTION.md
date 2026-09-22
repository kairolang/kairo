**Ordering is DAG order, not just parallel.** `CompilerInstance::_sema`
runs each fid's pipeline in reverse import-tree order. I needs it (source
overlay complete before re-export folds). T needs it (an imported file's
nodes are settled before the importer READS them). X needs it (an imported
expression-bodied function's return slot is filled by its own TU). Do not
change the loop.

Pipeline, as scheduled by `Sema.k`:

    P -> I -> E -> V -> N -> T (TypeResolve, RedeclMerge, ChainBinding)
      -> C (ConstraintExtraction, TypeCycleCheck, ExprTyper, ShadowCheck, ...)
      -> L -> M1 -> M2

**The dumps are pinned to phases, not to the end of the run.**
`--print-sema` dumps after `run_to(Checked)` -- X's output, before any
`Lower/` pass has rewritten the nodes it names (a list literal is still a
list literal, a cast is still a cast). `--print-lowered` is the same dump on
the far side of `Lower/`, and a test asserting what a lowering PRODUCED uses
that one. `--print-ast` is earlier still: it dumps at the end of P, before
sema runs at all. Splitting the run this way must not lose the hard stop --
a stage that returned false has already halted the pipeline, and the driver
does not re-enter (`Sema.k::_hard_stop`).

### 2.1 P parse [DONE]

POST: every DC has a frozen table; `out_of_line` collected.
INVARIANT: frozen tables are never mutated again by ANY later phase.

Statement-scope named decls (`class Local`, `fn inner` inside a body) are
linked into the enclosing executable DC's `dc_decls`
(`StmtParse::_attach_local_decl`, never for the TU). `_build_symbols`
indexes their BODIES through `_index_local_scopes` so members have tables;
their NAMES go in no table (N's lexical stack / T's `ltypes` own them).
`Self` in expression and pattern position lexes as `BiSelf` and parses as
an ordinary `NamedIdentExpr` head; `Self<...>` never takes generic args.

    [MISSING] `TypeCastExpr::cast_mode` (Default / Static / Const /
    Unsafe). Only `is_unsafe` is recorded today; `as static` / `as const`
    parse but are not distinguishable by sema.                        (spec 3)
    [MISSING] Named call arguments have no node; every argument is
    positional until one exists.                                      (spec 8)
    [MISSING] `<T: type>` -> `GenericParamKindBound::Duck`.
    [MISSING] `PointerType::is_unsafe` stamped from the `unsafe` qual. (spec 2)

### 2.2 I ImportResolution [DONE, IMPORTS.md §4]

path->fid is the PP's; keys re-intern once at the boundary; overlay cells
are thin and multi-target; plain imports bind ONE name (the ModuleDecl);
import everything, carry the visibility fact, diagnose at use; two walls
against accidental transitivity; NO unfold pass, NO fwd-decl synthesis.

Selective and symbol-path imports of a name the source RE-EXPORTS
(`import foo::{bar}` where foo `pub import`s bar) probe the source's
overlay on a table miss (`_reexported_cell`). Wildcards fold re-exports.

### 2.3 E Expand [PARTIAL]

`RequiresDesugar` runs. Macro expansion and eval lowering do not.

### 2.4 V Verify [DONE]

Six independent structural checks. Errors hard-stop before N.

### 2.5 N NameResolution [DONE]

`Sema/Resolve/NameResolution.k`. Two halves, one pass.

(a) Decl validation over frozen cells: link `Redeclarable` chains for the
five type kinds + modules, retarget canonical at the definition, diagnose
redefinition and conflicting kinds, attach `out_of_line` defs, populate
`sc.well_known`. **Specializations are skipped**: their own chains link in
T on canonical spec args (#12). Function chains are R's (§2.6a).
**Modules reopen**: every `module Foo { }` block is a definition, so two
defining links is legal for a ModuleDecl ring (`_reopenable`) and a
redefinition for the five type kinds. `unqualified` treats a module scope
as its whole ring (IMPORTS.md §4.3).

(b) Binding: every `NamedIdentExpr` head gets `resolved_decl` or
`candidate_cell`. Order: lexical locals stack (innermost first) ->
`sc->lookup.unqualified(cur_dc)` -> miss. Redecl chains collapse to the
representative; specializations never compete for a name; a genuine
overload set goes through whole.

    [DONE] Lexical stack holds: params, generic params of the enclosing
    function/type, statement binders (`for`, `catch`, destructuring,
    `case var n`, context bindings), body `var`s (declared AFTER their
    initializer), and statement-scope named decls (`fn inner`, `class
    Local`, `type X` -- declared BEFORE their body, so recursion binds).
    C-style `for var i = ...` scopes `i` to the loop.
    [DONE] `Self` (BiSelf) in expression position binds to the enclosing
    type body's decl -- the class/struct/... or the ExtensionDecl.
    [REMOVED] The bare-ffi miss gate. ffi imports bring real decls now
    (IMPORTS.md §5), so an unqualified miss is a miss in every TU.
    [DONE] Out-of-line body of a member whose OWNER is in another TU
    (`fn S::g` in a Kairo file, S from a header). cur_dc is the owner's
    scope, keyed by the header TU and parented to the header's file, so
    the plain walk probed it with this TU's imm (a silent wrong member) and
    never reached the file the definition was written in. Order, as C++
    for a member body: locals -> the owner chain (class, enclosing
    namespaces; stops before the header's file scope, never reads its
    overlay), probed by SPELLING -> the definition's lexical_dc through
    plain `unqualified`. `NameLookup::unqualified_out_of_line`; entered only
    through `_lookup_unqualified` while `_ool_lexical` is set, so every
    other walk is unchanged. T mirrors it for type heads.
    [DONE] Attaching an out-of-line def (a) and matching it to an overload
    (R(b)) probe the owner through `MemberLookup::in_scope`, spelled; the
    ctor test compares SPELLINGS, each through its own TU's context.
    [DONE, by design] N does NOT bind: chain steps (ChainBinding);
    ConstructorPattern heads and bare `case n` (pattern checking);
    named-initializer field names (X); attribute ARGUMENTS.
    [DONE] The explicit-qualifier rule (R049), below.

**The explicit-qualifier rule.** Kairo has no implicit `this->`. A name that a
TYPE scope answers, used from inside a function or closure body, is a MEMBER
ACCESS with the qualifier left off, and it is an error: `self.x` for an
instance member, `Self::x` (or the type's own name) for a static one. The ONE
exception is a name that denotes a SCOPE -- a nested type, a type alias, a
nested module -- because naming a type is not an access through an object;
`Nested { .. }` inside a method means `Self::Nested` and stays legal.

Two mechanisms: N's `_fn_depth` counter plus `_ext_target` (probed AFTER the
DC chain); T's `_lookup_in_selfs` for type position. Field defaults and enum
variant values keep the type body's scope (`_fn_depth` resets to 0 on entry
to every type scope).

**Lang items are bound by fid + path** [DONE]. The compiler ships a root
named `builtin` (`Lib/builtin`, installed to `<resource-dir>/builtin`,
`--builtins-dir` overrides). The driver folds it into every non-builtin
TU's import graph and synthesizes one `ImportDecl` (`is_prelude`) per TU
equivalent to `import builtin::*`, after parse and before I;
`--no-builtins` suppresses the import, `--no-prelude` also stops the root
being folded. `WellKnownDecls` lives on `GlobalDisambigTable`, filled once
per build from the builtin fid between that fid's N and T, by qualified
path; no TU walks its own root by name. `NameBindingVerifier` unchanged.

`NameBindingVerifier` is N's exit test: no reachable `NamedIdentExpr`
survives with both slots null unless poisoned.

### 2.6 T TypeResolution [DONE]

`Sema/Resolve/TypeResolve.k`. Every type node gets `canonical`,
`type_flags`, per-segment `resolved_*`. Poisons on error.

**T never rewrites a node.** Slots only.

**Post-order, demand-driven.** `dispatch_type` resolves children first.
Aliases expand on demand (`_expand_alias`), memoized on ResolutionState;
`type A = B; type B = A` is one error with every link as a note.

**Alias chain depth is its own budget** (`--cmax-type-alias-depth`, default
64). The resolution stack's cap stays as the backstop and reports a
different message naming `--cmax-scope-depth`. Both are `R036`.

**An alias may not be more visible than what it names** (`R050`, at the
alias DECLARATION, walking the SYNTACTIC target).

**T never dispatches a node it does not own.** Foreign slots are READ
(`_foreign`); DAG order guarantees they are filled.

**Unqualified lookup uses the overlay of the TU the walk started in.**

What T decides:
- **Builtins** by token kind, before any lookup. `i32::x`: error.
- **`self`/`Self` in type position**: the innermost type scope's record with
  its own params as args. `Self::Inner` is a HEAD. `Self<T>` is an error.
- **Heads**: generic frames -> `ltypes` -> `unqualified(cur_dc)`. Inside an
  out-of-line body whose owner is in another TU, the last step is
  `unqualified_out_of_line` (§ N(b)). `_primary_of_spec` applies the same
  rule to a spec whose semantic scope is an imported primary's.
- **`::` segments** step through `context_of(decl)`, alias expanded first,
  spelled for cross-TU probes. `T::Item` and `Foo<T>::Inner` are marked
  dependent and stopped (#5); M2 owns member-of-instantiation. The one
  exception is an IMPORTED `Foo` with concrete args: `Foo<Args>::Inner`
  steps into the registry instance, which `_scope_of` has clang fill first
  (`MemberLookup::ensure_filled`, IMPORTS.md §5); only a failed fill defers.
- **Final decl -> canonical**: GenericParamDecl -> `generic_param(owner,
  index)` on the REPRESENTATIVE; alias -> expand; nominal -> arity -> args
  by position and name -> defaults in the PRIMARY's scope -> #12. A written
  const/volatile wraps the canonical (`qualified()`); identity keeps it.
  Reference kinds put it on the referee.
- **Specialization registration** (#12) via `_register_specs_in`.
- **Structural kinds** ask the store. `[T; N]` canonicalizes only for a
  literal N. Dependence always flows up (`_component_ok`).
- **Receiver synthesis.** `ParamDecl::create_self` leaves `type_` null; T
  writes a `SelfType` with the enclosing record as canonical.
- **#68 refinement**; **enum underlying** must be a builtin integer;
  **`extend` target** resolved first; a record target becomes Self.

**Containers are records, not structural kinds** [DECIDED; migration in
progress]. `[T;]`, `[T]`, `{T}`, `{K: V}` and `string` are sugar for
`builtin::Slice<T>`, `Vector<T>`, `HashSet<T>`, `HashMap<K, V>`, `string` --
decls in the builtin root reached through `sc->well_known`.
`_resolve_vector/_set/_map` and the incomplete-array arm produce
`record(item, args)`; an unbound item is R053E at the use. The store's
`vector()/set_of()/map_of()` and MemberLookup's `_ext_by_shape` are
deleted; `VectorType`/`SetType`/`MapType` remain as syntax nodes whose
canonical is a `RecordType`. `extend <T> [T]` is legal syntax for
`extend <T> Vector<T>`. `*T`, tuples, fn pointers and `[T; N]` stay
structural (`[T; N]` needs const generic arguments in the registry key
before it can be a record; it is also the FFI shape of a C array). An
FFI-imported incomplete array keeps the structural `array(elem, 0)`. A
`[...]` literal is a `Slice<E>` (or takes an expected `[E; N]` outright);
`Slice<T> -> Vector<T>` is the one container conversion, rank Converted.

**`unsafe *T` is a distinct canonical from `*T`** [DECIDED, MISSING, spec 2].
`PointerType::is_unsafe` enters the store's key. Without it the `unsafe *`
cast family is undecidable.

**`_selfs` holds a `*Type`, not a `*Decl`** [DECIDED, MISSING]. A record's
self is `record(canon, args)`; a structural target's self is its canonical.
Closes residue (f): `Self` inside `extend i32` stops being "outside a type
body".

Error homes carry real diag-table codes. `R020`-`R050` are the name/type
domain; `SC003`-`SC016` the Verify passes; `I003E` invariant violations.
`ImportResolution` still shares `R015E` across three errors.

`R001`/`SC001`/`U001` remain the per-category placeholder codes. The whole
of `Sema/Type/` is on `SC001E`/`SC001W`; a later sweep triages it. Anything
still on a placeholder must not ship in a stable release.

    [PARTIAL] `Foo<i32>::Inner` (concrete args) is marked IsDependent, not
    merely instantiation-dependent; ChainBinding then refuses
    `Foo<i32>::Inner::make()`.
    [PARTIAL] `_register_specs_in` descends type and module scopes only.

### 2.6a R RedeclMerge [DONE]

`Sema/Resolve/RedeclMerge.k`, inside the T stage after TypeResolution.
Merges FUNCTION redeclarations by signature (arity, canonical param types
in order, generic arity; return type EXCLUDED so a mismatch is a conflict;
const excluded for Kairo-authored decls, included for foreign; top-level
parameter cv excluded as in C++ ([dcl.fct]/5), both the binding's `const`
and a `const` written at the top of the type, so `f(x: const *i32)` and
`f(x: *i32)` are one function while `f(*const i32)` and `f(*i32)` are two;
the receiver's `const` is one level down and stays). R(a) walks
frozen cells; R(b) matches `fn Class::method` against the in-class set.
Return-type / default / linkage / modifier agreement checked across the
chain. File scope permits repeats, a type body does not ([class.mem]).
A pair with DISTINCT signatures whose parameters all lower to the same C++
types is R052E at the second decl (`f(u64)` / `f(usize)` on a 64-bit
target: `usize` is `size_t`, the pointer-width unsigned integer), because
the emitted C++ would declare one function twice. Lowering compared is the
builtin table only (`usize`/`isize` vs the fixed-width integer of
`target.pointer_width`); records, pointers and refs compare by canonical as
identity does. Kairo-authored pairs only.

### 2.7 ChainBinding [DONE]

`Sema/Resolve/ChainBinding.k`, after RedeclMerge in the T stage. Walks
every `ChainExpr` left to right from an ANCHOR and binds each step:

    Module   -> `::` does table lookup (every reopened scope, unioned;
                re-exports via the module's overlay); `.` is an error
    Type     -> `::` does member lookup; `.` is an error
    Value    -> `.`/`->`/`?.`/`?->` peel the wrapper then member lookup on
                the canonical; `::` is an error
    NeedsInference / Errored -> record why, stop
    Dependent -> the three-regime rule below

Anchors: param/field/typed var -> Value; class/struct/enum/interface/
alias -> Type; `Self` bound to an ExtensionDecl -> Type (its target);
module -> Module; generic param -> Dependent (carrying its canonical);
call / inferred var / overload set / operator or tuple-index step ->
NeedsInference. An ffi alias denotes the header TUs' ModuleDecls, so it
anchors as Module like any reopened namespace. A module anchor's scopes
are its whole reopening RING (`NameLookup::module_scopes`, deduped), from a
single decl as much as from an all-module cell: N collapses a same-TU
reopened module to its canonical, and `Util::b` must still find a `b` that
lives in the second `module Util { }` block.

**Two callers, one binder** [DECIDED, MISSING, spec 4]. `bind_step(chain,
st, anchor)` is public. ChainBinding calls it from its own walk with the
anchors it can compute from DECLARED types; the expression typer calls it
for every NeedsInference step once it knows the base's type, with
`anchor_for_value(decl, canonical)` / `anchor_for_type(t)`.

**The three regimes** [DECIDED, MISSING]. A step on a value whose canonical
is a bare `generic_param(owner, i)` reads `owner`'s `GenericParamDecl[i]`
and its bounds (inline `impl`/`derives` plus the owner's requires
conjuncts, read from `sc->bounds`):

    <T>            opaque. No members, no `::`. ERROR at the definition:
                   "'T' has no known members; add 'impl I' or ': type'".
    <T impl I>     member lookup over I (and I's derives), unioned across
                   bounds. Binds to I's REQUIREMENT decl. `derives B`
                   bounds expose B's members likewise. Definition-side
                   checking: the error lands on the template, not on the
                   40th instantiation.
    <T: type>      duck. Every step Dependent; M2 checks per instance.

A dependent COMPOSITE (`*T`, `[T]`, an unfilled `Foo<T>::Inner`) is still
Dependent under every regime; it has no scope to look into.

    [DONE] A dependent RECORD is still looked up by name (`self.x` in
    `class <T> Foo` binds to the field).
    [DONE] `Box<i32>::make()`: a type head with explicit args anchors as
    the registry instance -- positional, complete, no packs, no names.
    [DONE] Cross-TU probes are spelled, not imm-keyed.

Commit rule: one decl -> `resolved_decl`; all functions ->
`candidate_cell`; distinct non-function entities under one name ->
ambiguity error. Outcomes recorded per step in `ResolutionTrace`.

### 2.8 C checks [PARTIAL]

In order: `ConstraintExtraction`, `TypeCycleCheck`, `ExprTyper` (§2.9),
`ShadowCheck`. `OperatorSignatureCheck`, `ConformanceChecking`,
`ConstChecking`, `AccessCheck`, `ExtensionOrphanCheck` are stubs / missing.

`ConstraintExtraction` partitions each decl's canonical `requires` into
conformance constraints vs value predicates and writes the result to
`sc->bounds` keyed by owner decl [DECIDED, MISSING] -- the bound table
ChainBinding's dependent path and ConformanceChecking read.

    [DECIDED] TypeCycleCheck / LayoutPass treat a `RecordType::decl` that
    is `is_instance() && !instantiated` as "size unknown until M2", never
    as empty.
    [DECIDED] `ShadowCheck` runs after X; it is silent for a binding whose
    type is still null.

### 2.9 X ExprTyper [DONE, one-shot; bug list open]

`Sema/Type/`. THE expression typer: overload resolution, inference and
checking are ONE demand-driven system, not three passes -- picking an
overload needs the argument types, typing the call needs the overload, and
a "type mismatch" is what falls out when no conversion exists. Built like
ASTParse: `ExprTyper` derives the RAV and one mixin per concern; the
mechanisms with no traversal are components held by value.

    ExprTyper.k          driver, memo, `type_of(e, expected)`, side tables
    TypeUtil.k           component: read-only type/decl queries, rendering
    Conversion.k         component: the lattice + the implicit relation
    OverloadResolution.k component: candidates + args -> one decl
    ArgumentDeduction.k  component: unify / substitute / member_through /
                         replace_self
    LiteralTyping.k      mixin: §5 of the lattice
    OperatorTyping.k     mixin: §6 of the lattice + user operators
    CallTyping.k         mixin: callee shapes, ctor calls, promotion
    MemberTyping.k       mixin: chains (NeedsInference re-entry), subscripts
    CastTyping.k         mixin: the `as` family
    ControlTyping.k      mixin: if/match/try joins, closures, initializers,
                         lang-item desugars, binder-typing half of patterns
    StmtTyping.k         mixin: frames, `return`, decls that infer,
                         conditions, binders (what "TypeChecking" was)

**What X writes, and nothing else** (hard invariant #7 extended):
`Expr::type_`, `value_category`, `expr_flags`, `poisoned`; the inferred
type of a `VariableDecl` / `ClosureExpr` / expr-bodied `FunctionDecl` /
binder decl -- as the CANONICAL NODE ITSELF, which is self-canonical, so
every consumer reading `->canonical` is unchanged and no node is
allocated; and the promotion `candidate_cell -> resolved_decl` on a callee
(`NamedIdentExpr` or `ChainExpr::Step`). Never a new AST node.

Plus two facts on operator and call nodes that are slots, not nodes:
`resolved_op`/`op_via_free` on Binary/Unary/Assign/Subscript/`TypeCastExpr`
(the user operator overload resolution selected), and
`CallExpr::param_map`/`pack_len` (argument placement over `f->params`,
`self` included, -1 = default). Both are read by `Lower/` only.

**Four terminal states per expression.** typed (`type_` set); poisoned
(diagnosed, `type_` null); unknown (`IsInstantiationDependent` set,
`type_` null, not poisoned: dependent, foreign, or a hole a later pass
owns -- consumers skip checks on it); type/module-denoting (recorded in the
typer's side tables; only a callee or initializer head may read it).

**Memoized on the node.** `expected` is bidirectional only where a node
consumes it: literals, `null`, aggregate/named/anonymous initializers,
closures. A node has one parent, so one expected type, so the memo is
sound. Statement overrides call `type_of` with the expected type BEFORE
the RAV's own pre-order visit, which is then a memo hit.

**Conversion relation** (`Conversion.k`, normative source: the Primitive
Conversion Lattice). Two ranks: Exact = I; Converted = W, `T -> T?`,
`*Derived -> *Base` (same safety), `! -> anything`. No ordering inside
rank 2. `-fno-implicit-conv` demotes W to Converted->None here and nowhere
else. The primitive relation is rule-based (R1-R5, §4); the table-generated
`classify` with property tests is a tooling follow-up and these rules are
its oracle. bf16 -> f32/f64 is W (exact by construction; the doc table
omits bf16).

**Literals** (§5). Untyped until assigned. Expected type first, fit checked
AT the literal; default i32 -> i64 -> i128, then "too large without a
suffix". `-lit` folds the sign into the fit. Suffixed literals are typed
at the literal. Against a parameter, an untyped literal ranks Exact for
any type it fits (it TAKES the type; it is not converted) and is typed
with the parameter type after selection. The lexer's min-width guess is
not read for unsuffixed literals.

**List literals** (`LiteralTyping::type_list_literal`). A `[...]` literal
takes its type from the TARGET, the same way a scalar literal does:
`[T; N]` (the count must match the target's, else an error), `[T;]` a
Slice, `[T]` a Vector. With no container target it is `[T; N]` over the
join of its elements. Empty with no target is an error, as `null` is.

In argument position it is deferred exactly like a scalar literal
(`LitKind::List`, the element shapes in `ArgInfo::elems`): ranked by SHAPE,
typed after selection. Rank (`_rank_list`): `[T; N]` with a matching count
is the literal's own type and ranks as its worst element does (Exact when
every element is Exact); Slice and Vector are Converted and unordered
against each other, so those two overloads ALONE are ambiguous -- the same
answer C++ gives for span vs vector. Deduction against a dependent
parameter goes through the element join (`_list_default`) and yields an
array, a slice or a vector by the parameter's shape.

X records three facts on the node, and the lowering decides nothing:
`slice_ctor` and `owner_ctor` -- found by SHAPE through the lang item
(parameter count, and whether the single parameter is a Slice), never by
name -- and `storage`, `FullExpr` or `Extended`. Extended means the literal
directly initializes a `var`, and it propagates into nested slice literals.

Lifetime errors (`SC001E` for now): a slice-typed literal RETURNED, as the
RHS of `=`, as a field default, or as an initializer's value for a
slice-typed field. Those are the positions with no scope to extend a
backing array into. Documented hole: a callee that RETAINS a slice
argument is not decidable here; that is AMT's escape clause (Stage 2).

`[T;] -> [T]` is not implicit -- it allocates. Write `s as [T]`, which goes
through Vector's converting constructor: CastTyping rung 5d records
`TypeCastExpr::resolved_ctor`, and OperatorLowering rewrites the cast into
the construction. A literal never needs the cast; it takes `[T]` directly.

`[T; N]` is a C array, and X enforces the four rules that follow from that:
it is not copied (`_reject_array_copy`: an array is initialized from a list
literal and from nothing else), not assigned, not passed by value (write
`const`, `@inout`, or take a slice), and not returned (return `[T]` or fill
an `@inout` parameter). It is a local, a field, a literal, a `const`/
`@inout` parameter, and what a slice views.

**Overload resolution** (`OverloadResolution.k`). Viability: placement
(positional, named, pack tail), defaults, every placed arg at rank <=
Converted, generic candidates deduce every non-pack param. Rank = worst
argument rank. Ties inside a rank are ambiguous, with ONE tiebreak that is
not a conversion ordering: among Exact winners a non-generic candidate
beats a generic one (otherwise `fn f(i32)` beside `fn <T> f(T)` is
ambiguous on every call). A fwd/def pair is one candidate (representative).
Specializations are skipped (paired later). Packs are accepted at
Converted and not deduced. Diagnostics: no viable (capped candidate notes),
ambiguous, not callable.

**Deduction** (`ArgumentDeduction.k`). Structural unify of the param's
canonical against the arg's, binding `(owner, index)`; conflicts fail,
there is no common-type search. Top level may succeed through the implicit
relation (Converted); inside a structure exact or nothing. `substitute`
rebuilds through the store and goes through the registry for a concrete
record. `member_through(recv, mt)` reads a member type through the
receiver's args. `replace_self(t, I, T)` reads an interface member through
a bound (`-> Self` is `T`).

**Calls** (`CallTyping.k`). Callee shapes: name (function / set / type ->
ctor / fn-pointer value), chain (method or set with the chain's receiver /
type -> ctor / fn-pointer value), anything else must be a fn pointer.
Constructors live in the type's own table under `DeclName::ctor()`; no
ctor + no args is the default ctor. Args are typed before resolution
except untyped literals (ranked by shape, typed after). Generic function
instances are registered in `InstantiationRegistry` (needs the function
arm, spec 7). Return type: declared -> canonical; `-> !` -> `Never`;
expr-bodied unannotated -> demanded under a rstate cycle guard.

**Chains** (`MemberTyping.k`). Per step: field/var/param -> declared type
through the receiver (LValue); variant -> the enum; method/set -> callable
(no type; legal only as a callee); nested type/alias -> type-denoting;
module -> nothing; `.0` -> the element; operator step -> callable via
`op_name`. `?.` peels and re-wraps. Callable expressions have no type: a
unique non-method function named as a value is its fn pointer; an overload
set as a value is an error at the use.

**Operators** (`OperatorTyping.k`). Builtins follow §6 exactly (`u32 + i32`
is an error; shifts unify the right operand alone; compound assignment
converts the right operand only). Comparison -> bool; `<=>` -> `Ordering`;
`??` on `T?` joins the inner with the right; `===` requires unifiable
operands. Non-primitives search the LEFT operand's members and extensions
under `op_name`, plus free operator functions found by ADL in the modules of
EITHER operand's type (`MemberLookup::associated_scopes`: the enclosing
modules up to, not including, the TU; pointers/refs/nullables peel; generic
args recurse). Members and frees rank in ONE set
(`OverloadResolution::resolve_mixed`), so a tie between them is ambiguous.
An unqualified call gets the same ADL over its arguments unless ordinary
lookup found a method.
Literal-on-one-side takes the other side's type. `&x` needs an lvalue and
yields `*T`; `*p` yields the pointee as an lvalue.

**Casts** (`CastTyping.k`). The written target is the result type, always.
Dispatch on (source, target), first match, no fallthrough:

    1. target = source + const           const cast, one-way
    2. target is `unsafe *X`             reinterpret; needs an unsafe ctx;
                                         source any pointer or an integer
    3. target `*X`, source `*S`, related upcast: static, redundant lint;
                                         downcast: ASSERTING (panic site,
                                         S must be polymorphic)
    4. target `*X?`, related             checked downcast, null on miss
    5. static ladder: lattice I/W (lint) / E / U (unsafe ctx) / X (error)
       -> plain enum <-> exact underlying -> `op as` on the source ->
       one-param ctor on the target -> error. `op as` beats ctor.

`as static` disables 3-4 and errors on a dynamic answer; a static downcast
is forbidden outright. `as const` asserts 1. `T? as T` is an error naming
`??` / `unwrap!()`; there is no collapsing cast. Pointer <-> integer: `ptr
as usize` needs no unsafe; `ptr as u8` is an error; `int as unsafe *T`
needs unsafe; `int as *T` is an error; `*T as unsafe *T` needs unsafe.
Asserting downcasts are recorded in `panic_sites()` for
PanicEffectChecking.

**Control** (`ControlTyping.k`). if/match/try as expressions join their
arms (`Conversion::join`: identical, one-way W, or Never on one side);
every arm must then convert to the join. Closures type as their fn-pointer
canonical; params must be annotated; return declared or inferred through
a frame. `a..b` -> `Range<elem>`; `await` on `Future<T>` -> `T`; `spawn`/
`thread` -> `Future<T>`; `sizeof`/`alignof` -> usize; `typeof x` is
type-denoting; `unsafe e` bumps the unsafe depth; `delete p` needs a
pointer. Named initializer: fields by name in the record's table, values
against the field type through the receiver. Anonymous initializer needs
an expected record type. Patterns: binders take the scrutinee's type,
literal/range patterns are checked against it, tuple patterns split;
constructor heads and exhaustiveness are PatternChecking's.

**Statements** (`StmtTyping.k`). One frame per function/closure body:
declared return type (null = infer) and the join of returns seen.
`return` without a value in a non-void function, with a value in a void
one, or at all in a `!` function: errors. `var x = e` writes the canonical
into `type_`; `var x` with neither type nor init is an error; `void`
initializers are errors. Conditions and guards must be `bool`. `for x in
xs`: element from the container / map (K,V) tuple / string char / Range
arg / `op in` (through `Yield<T>`); binders get it through their
shorthands. Destructuring by position or field name. Context bindings take
the value's type until ContextLowering. `yield`'s check against `yield T`
is YieldLowering's.

**What X does NOT do**: ADL through the global namespace (a type at TU
scope associates no scope, by design; see `_enclosing_modules`); pack deduction and
ranking; pattern head resolution and exhaustiveness (PatternChecking);
const-correctness, including assignment to const and const-cast validity
beyond "adds const" (ConstChecking); effect propagation (reads
`panic_sites()`); access control (AccessCheck); `yield` vs `yield T`;
the context-binding protocol; the `: type` regime (M2 re-check).

**Depends on** (blocking, spec items 1-7): `BuiltinKind::Never`;
`PointerType::is_unsafe` in the store key; `TypeCastExpr::cast_mode`;
`ChainBinding::{prepare, bind_step, anchor_for_value, anchor_for_type}`;
`SC001E`/`SC001W`; the schedule line in `Sema.k`; the registry's function
arm. Non-blocking: named-argument node; SemaDump `-- expression types --`
section; TypeQual enum path in `TypeUtil::syntax_is_const`.

**Tests** (`Tests/Sema/ExprTyper/`, golden `--print-sema` dumps):
`literals.k`, `operators.k` (the §6 table verbatim), `overloads.k`,
`chains.k`, `casts.k` (one line per ladder branch), `control.k`,
`bounds.k` (the three regimes), `nomono.k` (a generic body: every row
`<unknown>`, zero diagnostics -- if this one fails, something treats
dependent as failed, and that is the first bug to fix).

### 2.10 L Lower [IN PROGRESS], M1, M2 [MISSING]

`Lower/` reduces the tree to the C++-shaped core EmitIR emits (CODEGEN.md
§6). Order, fixed: OperatorLowering -> CallLowering ->
ListLiteralLowering -> ExtensionLowering -> EnumLayoutLowering ->
NullableTypeLowering -> NullTestLowering -> CoalesceLowering ->
FStringLowering -> IterLowering -> MatchLowering/PatternCompilation ->
PanicLowering/FinallyLowering -> YieldLowering ->
TypeQueryLowering/NarrowedAccessLowering -> label lowering ->
CopyMoveLowering -> DestructorInsertion. Sugar first, control flow second,
lifecycle last. Every pass is an ASTWriter; a node a pass owns that reaches
codegen is an ICE naming the pass.

Mono model: "Kairo enumerates and checks; C++ instantiates explicitly".
M1 walks `InstantiationRegistry::collect`; it creates nothing (T and X
did). M2 is the sync point: fills `Instantiated` nodes from their pattern,
selects partials, runs dependent conformance, resolves `T::Item`, and
**re-checks every `: type` body per instance** by re-running X over the
body with a `Deduction` seeded from the instance's args
(`ExprTyper::retype_instance`, a second entry point, not a pass). A duck
body whose member resolves to an EXTENSION member is an error there (see
§2b, the `: type` rule).

---

## 2b. Member lookup, extensions & OOP

**MERGE, not hide** [DONE]. `MemberLookup::lookup(canonical, name, out)`
walks own table -> extensions -> bases breadth-first, deduped, UNION.

**Extensions** [DONE]: indexed once per run over every parsed TU. Records
keyed by `RecordType::decl` (the primary for `extend <T> Vec<T>`); an
instance decl also consults its `instantiated_from`'s extensions. Generic
extensions on structural types keyed by shape (goes away with the
container migration); exact non-generic targets by canonical pointer.

**Instances** [DONE]: an explicit spec walks its own body. An unfilled
implicit instance walks its pattern (`instantiated_from`). An instance of an
IMPORTED template is filled by clang, not M2: the first lookup into it
calls `ForeignInstantiate::fill` (IMPORTS.md §5), after which it is
`instantiated` and walks its own table like any filled instance. A failed
fill is sticky and leaves it on the pattern.

**Extension visibility is import-scoped** [DECIDED, MISSING]. Today the
index is build-global: `import std::Vec` does nothing except get the file
into the build, and two libraries in the build both adding `push` make
every `v.push` ambiguous. An extension contributes to a TU's lookup iff
its fid is in that TU's transitive import set. One filter on `_index_decl`.

**The orphan rule** [DECIDED, MISSING -> `ExtensionOrphanCheck`, Checks
stage, after T]. A plain `extend X` must be in X's file. `extend X impl
I` may be in X's file or I's file. Keyed on `RecordType::decl` of the
target (an explicit spec's extend lives in the spec's file; an implicit
instance's in the primary's). A rejected extend is poisoned so the index
skips it. Consequences: reopened modules do not relax it (file, not
module); an FFI-extracted C++ type can never be plain-extended.

**An `impl` extend may contain only the interface's members** [DECIDED,
MISSING -> ConformanceChecking]. Without this `interface Dummy {}` in any
file re-opens every cross-file conflict the orphan rule exists to prevent.

**Interface-conformance methods are ordinary members at lookup**
[DECIDED]. `v.push(x)` resolves the `VectorI` method bare. Two interfaces
both declaring `push` on one type collide at the use; the qualified call
form (`VectorI::push(v, x)` / `v.VectorI::push(x)`, spelling TBD) is the
tiebreak and is required before the ambiguity diagnostic can suggest it.

**Every extension member lowers to a free function with an explicit
receiver** [DECIDED]. `extend Foo { fn m(self) }` is `m(Foo*)` in the
extension's module namespace; `a.push(19)` -> `std::Vec::push(&a, 19)`,
qualified from `resolved_decl` (IMPORTS.md §6.5). Receiver `Self*` /
`const Self*` from `fn f(self)` / `fn f(self) const`; a prvalue receiver
(`f().push(1)`) is materialized into a temporary by ExtensionLowering.
Extension methods are never virtual, never `override`, never a ctor.
Record extends follow the same rule; there are not two.

**Friend iff the extend is in the type's file** [DECIDED]. The type's
emitted definition carries `friend` declarations for exactly its
same-file extension members, so they see `priv`; an `impl` extend in the
interface's file is pub-only. The friend list is therefore closed at the
file, so a class definition is byte-identical in every TU (IMPORTS.md
invariant 12), library builds cache, and adding an extend downstream
rebuilds nothing upstream. EmitPlan: a class at Complete admits its
same-file extension members at Fwd, placed BEFORE the class definition
(tier 0), since a namespaced friend needs a prior declaration. Generic:
`template<class T> struct Box { template<class U> friend void m(Box<U>*); }`.

**builtin declares, std extends** [DONE for the root; std pending].
`Lib/builtin` declares every lang item with fields and constructors only (a
struct may hold nothing else); std adds every method through `extend` in
its own files, which the orphan rule permits for impl extends and which
plain extends on builtin types are exempt from by the same file rule
applied to the root (`extend [T]` in std is an impl extend of a std
interface, or lands in a file the orphan rule accepts -- see
ExtensionOrphanCheck). Nothing is FFI-backed; the C++ spelling of
`Vector<T>` is derived from its decl like any record. Consequence kept: a
builtin type's representation is public API.

**Generic bodies and extension members: witness structs** [DECIDED,
MISSING]. A generic body emits ONCE as a C++ template. Inside
`fn <T impl VectorI> f(x: T) { x.push(1) }` no single C++ spelling reaches
a different free function per `T` (ADL searches the type's namespace, not
the extension's). So every interface gets a witness template, every
conformance a specialization, and bound-member calls go through it:

    template <class Self, class... IfaceArgs> struct VectorI_witness;   // interface's TU
    template <class T> struct VectorI_witness<builtins::Vector<T>, T> {  // conformance's TU
        static void push(builtins::Vector<T>* self, T x) { std::Vec::push(self, x); }
    };
    template <class T> void f(T x) { VectorI_witness<T, ...>::push(&x, 1); }

Uniform for own-method and extension conformances (the former forwards
to `self->m(...)`); covers methods, operators, constructors, statics.
Keyed on `(Self, interface args)`, so `impl VectorI<i32>` and
`impl VectorI<string>` on one type coexist -- and therefore an interface
bound MUST name every interface argument (`T impl VectorI<U>`); an
unparameterized bound on a generic interface is an error, never inferred.
Non-generic code never touches a witness. Homes: ConformanceChecking
builds the table `(type, interface instance) -> requirement -> witness
decl`; `Codegen/Emit/EmitWitness.k` emits primary + specializations;
EmitPlan adds the edge instance -> witnesses Complete in the instance's
HOME TU (§7: one instantiation site); EmitIR routes a call whose callee
bound to an interface requirement (`semantic_dc` owner is an
`InterfaceDecl`) through the witness. A conformance must be in the
instantiating TU's import set (same rule as extension visibility).

**The `: type` rule** [DECIDED]. Duck typing is C++ duck typing: a `: type`
body sees own members only. Extension members are unreachable under
`: type` (M2's re-check reports it, naming the interface to bound with).
One dispatch system, and a precise meaning: "T is a C++ type; clang checks
the body".

**`needs_using`** [MISSING]. **Virtual dispatch** [MISSING]. **Access
control** is a late filter [MISSING].

---

## 3. Hard invariants

Invariants 8-13, 9a and 9b live in `IMPORTS.md` §3 (imports, namespaces and
the emitted interface) and are part of this list by reference. Nothing checks
that the two stay in step, so a change to either is expected to touch both:
they are one list split by subject, not two lists.

Names the compiler knows but the user did not write -- lang items and lower
targets -- are defined in `AST/LangItems.k` and nowhere else (invariant 9b).
A pass that needs one asks that file; it never spells the string itself.

1. **Frozen means frozen.**
2. **One key space per TU.** Cross-TU goes through the spelling shim; the
   overlay consulted is the one of the TU the walk started in. A raw
   `lookup_symbol` / imm-keyed `unqualified` on a scope that may be foreign
   is a silent wrong answer, not a miss: the entry points that cross are
   `MemberLookup::in_scope`, `NameLookup::in_context` (with a spelling) and
   `NameLookup::unqualified_out_of_line`. The one walk that starts in a
   foreign chain from this TU's code -- an out-of-line body of an imported
   member -- also falls back to the definition's lexical scope, since the
   owner's parents are the header's, not this file's.
3. **One error, one home.** Import existence/ambiguity: I. Import access:
   N(b). Redefinition / conflicting kinds: N(a). Function redefinition /
   signature disagreement: R. Unresolved head, `Self` outside a type body
   (expression): N(b). Unknown type / arity / alias cycle / primitive
   misuse / no primary for a spec / spec redefinition / spec after
   instantiation: T. No member / wrong separator / member ambiguity /
   member of an unconstrained param: ChainBinding. Literal fit, operand
   unification, no viable overload, ambiguous call, bad cast, branch
   join, return-vs-signature, uninferrable decl: X. Dependent conformance:
   M2. Orphan violation: ExtensionOrphanCheck. Access: AccessCheck.
4. **Parallelism boundary.** P parallel. I, T, X DAG-ordered. N, M1 per-TU
   parallel. M2 sync. Store and registry are the shared mutable
   structures and both are locked.
5. **Dependent = deferred, not failed.** X's "unknown" state is this
   invariant on expressions; `nomono.k` is its test.
6. **Tracing never changes behavior.**
7. **One writer per fact.** Heads: N. Steps with declared bases:
   ChainBinding. Steps needing inference: ChainBinding's `bind_step`,
   called by X. Promotion cell->decl: X. `canonical`, `type_flags`,
   segment slots, `self` receiver type, `spec_kind` refinement, spec
   chain links, `instantiated_from` on specs: T. Function chains: R.
   `Expr::type_`, `value_category`, `expr_flags`, inferred decl slots: X.
   `instantiated_from` on implicit nodes: registry (then M2).
   `needs_using`: MemberLookup. `sc->bounds`: ConstraintExtraction.
8. **Canonical identity is build-wide, and cv-qualified: const i32 and i32
   are two canonicals.**
9. **T never rewrites nodes.** X never allocates nodes.
10. **Builtins are not names.**
11. **Imports are erased at N/CB.**
12. **`RecordType::decl` is the record whose body defines the instance.**
13. **T never dispatches a foreign node.** X reads a foreign decl's slots
    (return type, inferred var type) and never types a foreign body.
14. **The representative is the only identity.**
15. **The written cast target is the result type.** `a as T : T`, always.
16. **Two conversion ranks, unordered within rank 2.** The only tiebreak
    is non-generic over generic among Exact winners, and it is not a
    conversion ordering; `-fno-implicit-conv` can therefore remove a
    candidate but never select a different one (lattice §7).
17. **A generic parameter's regime is its declaration's.** `<T>` opaque,
    `<T impl I>` bounded, `<T: type>` duck. No inference of regime from use.
18. **A class definition is closed at its file.** Friends are same-file
    extension members only; nothing in another file changes the emitted
    definition.
19. **An interface bound names every interface argument.**

---

## 4. What remains, in the order it should be done

Blocking X (spec items; land before the bug sweep):

    1. BuiltinKind::Never                                    CanonicalNodes  small
    2. PointerType::is_unsafe in the store key               Types/Store/T   small
    3. TypeCastExpr::cast_mode + parser                      Expressions/P   small
    4. ChainBinding: prepare / bind_step / anchor_for_*      ChainBinding    small
    5. SC001E / SC001W placeholders                          diag table      trivial
    6. Sema.k schedule line; delete the four stubs           driver          trivial
    7. InstantiationRegistry function arm                    registry        small

Non-blocking, same subsystem:

    8.  Named-argument node (NamedArgExpr, ParamDecl::is_pack, parser/X     IN PROGRESS
        param_map)
    9.  SemaDump `-- expression types --` + inferred decls   dump            small
    10. TypeQual enum path check in TypeUtil                 X               trivial
    11. GenericParamKindBound::Duck; sc->bounds; the three-  P/C/CB/X        small
        regime bind_dependent_step; replace_self; receiver
        in OvlResult
    12. Tests/Sema/ExprTyper/* golden dumps                  tests

Name/type residue:

    a. Split ImportResolution's shared R015E                 diag table
    b. `Foo<i32>::Inner` dependence flag (§2.6 PARTIAL)      small
    c. `NameLookup::qualified_step` spelled overload         small
    d. Lang items by fid+path; containers as builtin records DONE (design);
       (§2.5, §2.6)                                           code: items 2-9 of
                                                              the container
                                                              ticket in flight
    e. `_register_specs_in` into executable scopes           small
    f. `_selfs` as *Type (§2.6)                               small
    g. closure bodies push a null DC                          small

Type domain (each unblocks the next):

    h. ExtensionOrphanCheck + import-scoped extension index   small
    i. ConformanceChecking: the conformance table, impl-only
       members, arity/Self checks, visibility at instantiation;
       instantiating a class with a `= virtual` method is an error
    j. PatternChecking: ctor-pattern heads, bare `case n`,
       `.Variant`, exhaustiveness
    k. ADL / free operator functions (X, OperatorTyping)     DONE
    l. AccessCheck (+ `prot` same-library provenance)
    m. ConstChecking, PanicEffectChecking (reads panic_sites)
    n. ExtensionLowering: `a.m()` -> `m(&a)`, prvalue receiver
       materialization, `semantic_dc` rewrite
    n2. CopyMoveLowering: copying a MOVE class is an error

Mono / codegen:

    o. M1 enumeration over the registry (types AND functions)
    p. M2: fill + partial selection + dependent conformance +
       `: type` re-check (`ExprTyper::retype_instance`)
    q. EmitWitness + EmitPlan witness edge + EmitIR witness calls
    r. EmitIR: `typename` / `.template` on Dependent segments/steps;
       generic emission; the fwd-decl emitter (IMPORTS.md items 12, 14)