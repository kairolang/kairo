**Ordering is DAG order, not just parallel.** `CompilerInstance::_sema`
runs each fid's pipeline in reverse import-tree order. I needs it (source
overlay complete before re-export folds). T needs it (an imported file's
nodes are settled before the importer READS them). X needs it (an imported
expression-bodied function's return slot is filled by its own TU). Do not
change the loop.

Pipeline, as scheduled by `Sema.k`:

    P -> I -> E -> V -> N -> T (TypeResolve, RedeclMerge, ChainBinding)
      -> C (ConstraintExtraction, TypeCycleCheck, ExprTyper, ShadowCheck,
            ... ConformanceChecking)                       => Typed
      == the panic-set barrier: every TU of the import cycle (one TU when
         there is none) is Typed, then EffectPropagation solves its sets ==
      -> C (PanicEffectChecking, EvalUsage, FeatureGate, ...) => Checked
      -> L -> M1 -> M2

**The Typed barrier** is the one place a TU waits for others (PANIC.md
§2.2: every TU's typing finishes before any panic set is final). A set is
the union of what a body raises and what its callees leave, and a callee
is always in the caller's import closure (an override's or a conformer's
set is bounded by the base's or the requirement's DECLARED set, P4), so a
TU's sets are final once every TU it reaches through imports is typed.
`CompilerInstance::_sema` therefore runs the graph in groups, one per
strongly connected component of the import graph (`ImportGroups`), each
after every group it imports, in the import order wherever that order
holds: every TU of a group goes to `SemaPhase::Typed` (through
ConformanceChecking), the build-wide `EffectTable` (Sema/Check/
EffectPropagation.k) registers the group's TUs that reached Typed and
solves every inferred set of the group to one fixpoint (§2.5), and then
each TU of the group goes on -- the late checks, `--print-sema`, the
lowerings, mono, the diagnostic drain. With no import cycle every group is
one TU and this is the one-TU-at-a-time loop it always was: a TU's lowering
still runs before the next TU is typed (NullTestLowering, for one, reads
the Nullable layout only once its TU has run EnumLayoutLowering). Only an
import cycle -- which has no order in which every callee is finished
first -- holds several TUs at Typed together; their Semas live until the
group ends, each at a fixed address (an arena: Sema keeps `&self.sc` from
its constructor on). Today the dependency scan drops a cyclic pair of user
files altogether (TICKETS), so a group of more than one TU does not occur
yet. A TU that stopped before Typed (a hard stop in I/N/T) is neither
registered nor continued; a call into it says nothing about panics. A run
with no driver table (`sc->effects` null) solves its own TU in
PanicEffectChecking, reading other TUs' sets as they were left.

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

**The declared panic set** (PANIC.md §2.2) is `panic_set`, a list of
written types, on FunctionDecl, ClosureExpr and FunctionPointerType; empty
for a bare `panic` and for no `panic`. `panic` followed by `(` on the same
line, in a specifier position (after a function's, closure's or `fn`
type's parameter list), is the set and never a tuple: no statement can
start there. A newline ends the specifier, so `var t: fn() panic` then
`(h)()` on the next line is a type and a call. `panic (x)` in a body is the
statement. `panic()` is S055E (fix-it: remove the list) and parses as a
bare `panic`. `fn op panic (const self) -> string` is an operator like
`op await` (nullary; C++ name `LowerTargets::op_panic`).

    [MISSING] `TypeCastExpr::cast_mode` (Default / Static / Const /
    Unsafe). Only `is_unsafe` is recorded today; `as static` / `as const`
    parse but are not distinguishable by sema.                        (spec 3)
    [DONE] `<T: type>` -> `GenericParamKindBound::Duck`, with the
    written `: type` range in `kind_bound_range`. Accepted only under
    -fduck-generics (MONO.md D1; FlagGates, §2.10 "The `: type` regime").
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

`EvalIfFolding` runs first (EVAL.md §4): every `eval if` whose condition
folds is replaced by its taken branch, the declarations of the others are
discarded, and each scope it folded in gets a NEW frozen table without
them (the parser indexed every branch; invariant #1 holds -- no table is
mutated, one is replaced, as `_bind_cxx` does). It must run before V and
N, which may not see an untaken branch, and after I, so a condition can
read an imported `eval` constant and clang's macro table is joined.
Being before T, it cannot fold `sizeof` / `alignof`: a declaration-scope
condition using one is an error whose note names what works instead
(`defined!(__LP64__)`, or an `eval if` in a function body, which is
`if constexpr`; EVAL.md 4.2b). Then `RequiresDesugar`. Macro expansion and eval lowering do not run.

### 2.4 V Verify [DONE]

Five independent structural checks. Errors hard-stop before N. (Unreachable
code was the sixth, lexically; it needs `!` types and is ControlFlowAnalysis
in C now, §2.8.)

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
`sc->lookup.unqualified(cur_dc)` -> the extend target (`_ext_target`) ->
clang builtins -> miss. Redecl chains collapse to the
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
    `.Variant` pattern heads (PatternTyping, against the scrutinee's
    enum); named-initializer field names (X); attribute ARGUMENTS.
    [DONE] Pattern heads are name uses. A bare identifier in a pattern is
    never a binder (binders are `var x` / `const x`), so `case MAX`,
    `case Color::Red` and `case Point(...)` heads are bound like any other
    expression; a bare head that misses is R020E with a "write 'var n'"
    note. Alternatives share binder decls: the first alternative of an arm
    (or of an `A | B` pattern) declares, and each later binder of the same
    name points at that decl.
    [DONE] The explicit-qualifier rule (R049), below.
    [DONE] Clang builtins, the fourth source of unqualified names, below.

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

Legal, but warned [DONE]: a bare nested type, type alias or associated type
of the record `Self` denotes at the use is SC001W with the fix-it inserting
`Self::` (readability: nothing at the use says the name is a member).
`MemberLookup::is_member_type_of` / `warn_unqualified_member_type`; N calls
them for expression position (`Node { .. }`, `Node::make()`), T for type
position, after the name has bound, so each use is warned once and binding
is unchanged. Only the INNERMOST Self: a sibling of an enclosing type seen
from a nested one, the type's own name, inherited nested types and nested
modules are not warned (`Self::` would name the wrong scope, or a module).
This is in any body, not only a function's: a field type or a method
signature in the class body is warned too.

**Clang builtins** [DONE]. A name clang knows as a builtin
(`__builtin_expect`, `__builtin_popcount`, ...) is a foreign function the TU
did not have to import. `Sema/Foreign/BuiltinImport.k` owns them: one
build-wide pseudo-header TU (`<kairo-clang-builtins>`, minted through
`HeaderIndex::ensure_target`) whose decls are made on first use from the
target's clang `Builtin::Context` (`Interop/Clang/BuiltinsSet.k`, owned by
`ClangBackend`). Rules:

- Resolved ONLY on a total miss in N(b) (`_bind_builtin`), after every Kairo
  source, so a declaration of the same name always wins. Nothing binds into
  the builtin TU's table, so it is never reachable qualified, never through
  an overlay, and never by T.
- Library builtins (`printf`, `memcpy`, ...) and header-dependent ones are
  NOT taken: they miss, and resolve the ordinary way through their header.
  Their `__builtin_` forms (`__builtin_memcpy`) ARE taken: clang's C++ gate
  is `isPredefinedLibFunction`, not `isLibFunction`.
- A builtin Kairo cannot type (per-call clang checking, a type only a header
  declares, an inexpressible parameter) binds to nothing: R057E at the use,
  poisoned.
- X: a builtin is callable and nothing else. CallTyping's name arm binds the
  callee without typing it, so reaching `_type_ident` with one is a value use:
  SC109E. Its `I` (integer constant) positions, `FunctionDecl::ffi_ice_mask`,
  are checked at the Kairo argument: SC108E. Only a literal (under unary
  `-`/`+`/`~`/`!`) counts until the evaluator lands.
- Wiring: `CompilerInstance` owns the `BuiltinImport`; the driver calls
  `be->startup()` (a join; normally long done) then `init` after header
  indexing and before the first SemaContext; `sc->builtins` is set beside
  `sc->foreign`. Null or unready means every builtin misses into R020E.

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

**A declaration's types resolve in the declaration's own lexical scope,
never in the scope of whoever demanded them.** Demand order may change WHEN
a type is resolved; it must never change WHAT it resolves to. Every
out-of-walk entry -- `_expand_alias`, `_demand_default`,
`_register_type_spec` -- goes through `_enter_decl_scope(d)` /
`_leave_decl_scope`, which clears the demand site's frames and selfs and
rebuilds `d`'s: walking `semantic_dc` outward to the first module or TU,
every type scope contributes its generic frame and its Self (an extension:
its own params, its target), a function its generic frame, Block and Lambda
scopes are skipped; then `d`'s own params. So `class <T> Box { type Elem =
T }` sees Box's `T` however Elem is first reached. Two exceptions, both
because a local decl can only be demanded from inside its own function:
`ltypes` is KEPT for a local decl (local types live on no table, only that
stack); and a statement-scope alias, which the parser leaves with no
`semantic_dc`, keeps the whole walk state, since it is resolved at its
DeclStmt before any use can name it. The remaining dispatches are use-site
by nature (a chain's generic args, a pack's param) or walk-only (an
extension's target).

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
- **A declared panic set's elements** are written types in the
  declaration's scope, resolved in the same walk as its parameters (a
  generic parameter of the function is in scope). On a `fn` type they are
  components (`_component_ok`): a poisoned element poisons the type. The
  effect is in the `fn` canonical key (`CanonicalTypeStore::func`:
  `canon_panics` and the canonical set, PANIC.md §2.2): `fn() panic(A, B)`
  and `fn() panic(B, A)` are one type, `fn() panic(A)` and `fn()` two,
  converted by subset (Conversion's fn rung). A function's value type
  carries its DECLARED set (ExprTyper::fn_pointer_type), a closure's its
  written one. Whether an element can be panicked at all is
  PanicEffectChecking's.
- **#68 refinement**; **enum underlying** must be a builtin integer;
  **`extend` target** resolved first; a record target becomes Self.

**Effect qualifiers on a written type are records too** [DONE]. `yield T`
canonicalizes to `Yield<T>` and `async T` to `Future<T>`, through the same
`_lang_record` as the containers, so a generator's value has the members
its lang class declares (`g.next()`, `g.current()`). The qualifier stays on
the syntax node: TypeUtil::is_generator_return and the typer frame read it
there (a spelled-out `Yield<T>` is an ordinary return), and an `async T`
frame types its `return`s against the inner T.

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

**An array length is folded here** (`_resolve_array`, EVAL.md 0.1): by
ConstEval, untyped -- literals, `eval` variables and `eval` fields (class
constants, EVAL.md 1.2), and the arithmetic over them. A length read from
an `eval` field of the field's own class whose initializer does not fold
(C++ would compute it, and inside its own body the class is incomplete) is
SC116E with a fix-it hoisting the constant to module scope (1.2a,
`_own_class_constant`; `_cur_field` is the field being resolved).

**What does not fold is kept for C++** (EVAL.md 0.2): a length or generic
value argument over value parameters (`N + 1`), eval constants whose
initializer does not fold, eval calls (`f(3)`), an enclosing unrolled
`eval for`'s binding, `+ - * / % << >> & | ^`, unary `-` / `~` and `as`
to an integer type becomes an interned canonical value node
(`TypeExpr`, `ValueOp`; `_value_expr`, `CanonicalTypeStore::value_expr`):
`[T; N + 1]` is `array_of_param(T, (N + 1))`, `Buf<f(3)>` has that node
as its argument. Identity is the expression's structure: `[i32; f(3)]` is
not `[i32; 4]`, as C++ treats a dependent expression before instantiation.
ArgumentDeduction substitutes a node's operands and folds it when they
are all values (ConstEval::value_node), so `Buf<3>`'s `[T; N + 1]` IS
`[T; 4]`; a computed argument or extent is a non-deduced context. A node
with an eval call or an eval constant in it is SC116E outside a function
body (`_value_placeable`): a field, a signature or a namespace-scope
binding is spelled before any consteval body or eval binding is defined.
A call of a non-eval function is SC001E with a fix-it. An eval class value
(7e) enters the same way: an eval binding of one (`Widget<CFG>`) is a
`Decl` node, an eval constructor call (`Grid<Pt(2, 3)>`) a `Call` node
naming the class.

**`unsafe *T` is a distinct canonical from `*T`** [DECIDED, MISSING, spec 2].
`PointerType::is_unsafe` enters the store's key. Without it the `unsafe *`
cast family is undecidable.

**`_selfs` holds a `*Type`, not a `*Decl`** [DONE]. A record body's self is
`record(canon, its own params)`; an extension's is its target's canonical,
pushed after the target resolves and popped with the extension. So inside
`extend <T> Wrap<Box<T>>`, `self` is `Wrap<Box<T>>` over the EXTENSION's T --
not `Wrap<T>` over Wrap's, which made `self.inner` read through the wrong
params (ChainBinding's `_seen_through` got the identity) and put Cell's T and
the extension's T on opposite sides of a return. Every reader takes the type:
receiver synthesis (wrapped in `const` for `const self`), `Self` in type
position, and `_lookup_in_selfs` (the record's decl; a non-record self has no
scope and is skipped). `Self` inside `extend i32` is i32, no longer "outside a
type body"; `Self::X` there is R026E. ChainBinding's ExtensionDecl anchor
keeps the record decl for lookup but carries the real target as its type, so
`Self::make()` in a generic extension sees the same `Wrap<Box<T>>`.

Error homes carry real diag-table codes. `R020`-`R057` are the name/type
domain; `SC003`-`SC016` the Verify passes; `I003E` invariant violations.
Clang builtins: `R057E` (N), `SC108E`/`SC109E` (X).
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
const excluded for Kairo-authored decls, included for foreign ones and
for `[]` (keyed on operator kind, `is_place_kind`, so place
and value forms alike: the one exception to the const-overload
restriction); fixity included, so `op l++` beside `op r++`
is two functions; top-level
parameter cv excluded as in C++ ([dcl.fct]/5), both the binding's `const`
and a `const` written at the top of the type, so `f(x: const *i32)` and
`f(x: *i32)` are one function while `f(*const i32)` and `f(*i32)` are two;
the receiver's `const` is one level down and stays; the `@copy` / `@move`
marker included when both decls carry one, since `other` is written bare
and ClassLifecycle stamps its mode only in the checks, so `@copy fn X(self,
const other: Self) = delete` beside `@move fn X(self, other: Self) =
delete` is X(const X&) and X(X&&), not one member twice). R(a) walks
frozen cells, and never merges two constructors that both carry a marker,
same kind or not: how many transfer constructors a class may have is
ClassLifecycle's rule (SC057E), which would otherwise lose a second
`@copy` differing only in `const` on `other` to R041E. R(b) matches
`fn Class::method` against the in-class set, marker kind included, so an
out-of-line definition that repeats the marker still finds its declaration.
Return-type / default / linkage / modifier agreement checked across the
chain. File scope permits repeats, a type body does not ([class.mem]).
A pair with DISTINCT signatures whose parameters all lower to the same C++
types is R052E at the second decl (`f(u64)` / `f(usize)` on a 64-bit
target: `usize` is `size_t`, the pointer-width unsigned integer), because
the emitted C++ would declare one function twice. Lowering compared is the
builtin table only (`usize`/`isize` vs the fixed-width integer of
`target.pointer_width`); records, pointers and refs compare by canonical as
identity does. Kairo-authored pairs only.

An out-of-line definition may not carry a default (R056E, in R(b)): a
method's defaults are its in-class declaration's. The default is cleared
once diagnosed and the definition still links. Free-function
redeclarations still accumulate defaults.

`inline` is part of modifier agreement for Kairo-authored links (R039E),
though C++ lets a later declaration add it: it decides where the body is
emitted (CODEGEN.md §7), and an importer reads it off the in-class
declaration while the home TU reads the definition. After both R(a) and
R(b), R(c) reports every Kairo `inline` function whose chain has no
definition (R001E, placeholder): it would be declared inline in C++ with a
definition nowhere. Per TU, so the body has to be in the declaring file --
which an importer needs anyway. `= default` / `= delete` / `= virtual`
count as bodies.

`where` groups (where.mdx). Two same-signature functions either of which
has a `where` guard are never linked: they are members of one dispatch
group, not one entity. After the pairwise loop, R(a) stamps
`FunctionDecl::where_lead` -- the first member in the cell, which is
source order -- on every safe, unpoisoned function sharing a guarded
one's signature. An `unsafe` function is never a member. Two UNGUARDED
same-signature definitions still link, so a second fallback is R029E.
OverloadResolution maps every candidate to its `where_lead` before it
dedups, so a group is one candidate with one signature and every call,
in every TU, binds to the lead. A dependent signature never compares
equal (above), so generic functions do not group (WhereGuardCheck gates
them, SC116E).

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
module -> Module; generic param -> Dependent (carrying its canonical),
except a value parameter of an eval class (`<eval C: Config>`, EVAL.md
7e), which is a Value of that class (`C.size` is Config's field);
call / inferred var / overload set / operator or tuple-index step ->
NeedsInference. So is a `.` / `->` step on a value whose declared type is
NULLABLE: whether it reads the value depends on the nullness analysis at
that use (NULLABLE.md §4), which only the typer has, so MemberTyping binds
it on the narrowed `T` or reports the nullness error; when MemberTyping is
the caller (`bind_step`) a nullable anchor is bound as is, and fails with
"no member in 'T?'". An ffi alias denotes the header TUs' ModuleDecls, so it
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
                   bounds expose B's members likewise. An operator on
                   T -- `op []` included (MemberTyping) -- gathers from
                   the same bounds (OperatorTyping::bound_ifaces) and
                   nothing else. Definition-side
                   checking: the error lands on the template, not on the
                   40th instantiation.
    <T: type>      duck, behind -fduck-generics. Every step Dependent and
                   left unbound; codegen spells it as written and clang
                   checks each instance. Kairo never re-checks the body.

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

In order (`Sema.k::_stage_checks`): `TypeCycleCheck`,
`OperatorSignatureCheck`, `PackChecking` (where a type pack, a pack
parameter and a pack-expanded variant may appear; before X, on N's names
and T's types; an enum it rejects is poisoned), `ExprTyper` (§2.9), `ValueCategoryPass`,
`ShadowCheck`, `ShorthandLint` (NULLABLE.md 1.8), `PatternChecking`,
`ReturnPathCheck`, `ControlFlowAnalysis`, JumpLabelCheck's script rule,
`WhereGuardCheck`, `ClassLifecycle`, `ClosureCaptures`,
`MoveCheck`, `InitCheck`,
`CtorInitCheck`, `ConformanceChecking` -- Typed, the panic-set barrier
(top of this file) -- `PanicEffectChecking`, `EvalUsageChecking` (EVAL.md §6:
what an eval context, `eval for` and a body `eval if` may hold; needs X's
callee bindings; also marks every string literal C++ reads at compile time,
`StringLiteralExpr::const_eval`, for StringLowering, EVAL.md 2a), `FeatureGateCheck`, `FlagGates`,
`PatternCompilation`. (`ConstraintExtraction` runs in T, before
ChainBinding, §2.6.)

`WhereGuardCheck` [DONE] judges each `where` group: a guard on an
interface method, an `unsafe` overload or a bodiless declaration, a group
with no fallback, and members disagreeing on return type, `const self`,
`inline`, `-> !` or linkage are SC001E; virtual, `panic`, generic,
extension, operator, constructor, out-of-line, forward-declared,
generator, `async`, defaulted and variadic members are SC116E (`where` on
an `eval` fn is EvalUsageChecking's SC001E).
Guards that are conjunctions of integer-parameter-vs-constant comparisons
(and bool parameters) are boxes; a box inside an earlier one (or inside
the union of earlier one-parameter boxes) is unreachable, a box meeting
an earlier one with neither inside the other overlaps, an empty one never
holds: SC001W. Boxes covering every value are a fallback. Each passed
group goes to `SemaContext::where_groups` in dispatch order.

`PatternChecking` [DONE] is usefulness over a pattern matrix: SC120E for a
non-exhaustive match (statement form too), with a witness; SC121E for an
arm that can never match, SC122E for such an alternative. It writes
`is_exhaustive` / `covering_arm` / `open_tail` on every `MatchStmt` /
`MatchExpr`. A match on a `T?` that answers null first (X's `null_arm`,
NULLABLE.md 3.6) is checked over its other arms with the column `T`. Integer columns are cut into segments, so ranges can complete
a type; flags enums and imported C++ enums are open and need `default`.
`ConstChecking`, `AccessCheck`, `ExtensionOrphanCheck` are stubs /
missing.

`ClosureCaptures` [DONE] decides what every closure captures and how
(closures.md, Capture Modes), and records it on the ClosureExpr
(`cap_decls` / `cap_modes` / `cap_via_ptr` / `cap_uses`): the closure's
free automatic bindings (FreeVarScan; statics and globals are named, not
captured), by copy with no list (a MOVE type: moved in, ownership.md), by
pointer under `|*|` / `|const *|`, as written in a named list, and `self`
implicitly as the pointer it is. A binding an enclosing closure holds by
pointer is that pointer inside (X's `_capture_view`), so an inner capture
copies or converts it. A free binding that a named list or `||` leaves out
is SC001E at its first use, a note at its declaration, and a fix-it that
names it. MoveCheck reads each capture as a read where the closure is made
and a Move capture as a move; FinallyLowering and EmitIR read the rest.

`MoveCheck` [PARTIAL] decides every move and checks use-after-move
(SC052E). A `@move` argument moves; so does a MOVE value transferred: by
value, into a C++ `T&&`, into a variable, by assignment, out of a return
that is not a bare local. It records each transfer site for
CopyMoveLowering. Bindings and field paths under them (`p.a`) are
tracked; pointers and `self` are not. A closure's captures are reads of
the bindings where it is made, and a MOVE value captured by copy is moved
into it (ClosureCaptures). Path-insensitive: a move
in the right operand of `&&` leaves the binding maybe-moved after it.

`InitCheck` [PARTIAL] checks one rule so far: a field's default reads
only fields declared before it (SC001E naming both, with a note at the
later one). A default keeps the type body's scope, so it may name a
sibling bare, and it runs as a C++ default member initializer, in
declaration order; the field itself and every later one are not built
yet. A static field is never refused. A static's own initializer reads
no instance field (SC001E: it runs for no object), and a static with no
initializer needs a type with a default (SC001E, as a `var x: T` does:
it is defined `T R::s{}`). It also gates (SC116E) an earlier sibling read
in a GENERIC record's default, which the thunk's qualified spelling
cannot compile yet: CXXSpell gives the record no template arguments
there.

`CtorInitCheck` [DONE] is the const-field rule (classes.md, Const members
in constructors), structural like ReturnPathCheck. A const field with no
declared initializer is assigned on every path through each constructor,
exactly once (never in a loop); one with an initializer is never
assigned; outside a constructor of its own record no const field is
assigned at all. A field with no initializer whose type has no default
(`TypeUtil::why_no_default`, the answer InitCheck gives a local: `bool`,
an enum with payloads, a record with no usable default constructor, an
array of those) is required the same way: the constructor's first whole
write is its initializer, on every path, and later writes are
assignments; writing part of it (`self.f[i] = e`) before that is an
error, except that a one-dimensional array field of known length (not
const) may instead be built element by element: `self.f[k] = e`, k a
constant (ConstEval), every k in 0..N-1 exactly once on every path,
outside any loop, before `f` or `self` is read. The flow state tracks
each such element as it tracks a field (CtorFlow::edef / emaybe); the
array counts as assigned when its last element is, and the write that
builds an element is marked `AssignOperatorExpr::ci_elem_init` for EmitIR.
Missing elements (named), a duplicate, a non-constant or out-of-range
index, a loop, a read before the last element: SC001E. A write into an
element (`self.f[k].x = e`) and an array of arrays build nothing (a note
says so). An array field is assigned once: its one whole write in a
constructor initializes it, on every path or none, and any other is
SC071E (OperatorTyping defers exactly that write to this pass). The
constructor body is read in two parts at the frontier, the last
top-level statement that assigns a const or array field whole or, for
each other required field (and each array built element by element),
the first after which it is assigned on every path (a quiet walk),
whichever is later: S_pre runs before the object
exists, so in it `self` appears only as `self.f = e` or as a read of a
field already assigned on every path, and it holds no `return`. Every
rule is SC001E but the array one; SC116E gates a generic constructor and
`try` / `finally` / `inline` / `label!` / `jump!` in S_pre, a static or
array local carried across, and an array field of arrays or of a generic
length initialized in place. It writes the cut
(`FunctionDecl::ci_split`, `ci_index`, `ci_slots`, `ci_dense`) for
CtorInitLowering and the emitters (CODEGEN.md §6). ClassLifecycle makes
a record with a const field unassignable member by member (SC071E), as
C++ does; a transfer constructor with a body still rebuilds it.

`FeatureGateCheck` [DONE] runs after the other checks (only FlagGates and
PatternCompilation follow it) and reports well-typed constructs that
have no lowering yet, one SC116E each ("<construct> is not yet supported").
Lowerings carry no diagnostics, and they run under `--type-check-only`, so
an unfinished feature is said HERE; the error stops the schedule before L
and the lowering's ICE stays an invariant. Gated today: a ranged `for` whose
`iter_kind` is Vector, Set, Map or String, and a non-generic ADT enum one of
whose lifecycle facts is Unknown (`lifecycle_open`; EnumLayoutLowering picks
its special members from those facts), and an initializer on an eval
field or on an array-typed field that FieldInitLowering cannot take
element by element (a static one, an array of arrays, anything but a
list literal), and a
generic closure (`fn <T>(x: T)`: X types neither its parameters nor a
call of it). A gate is removed in the commit that lands its lowering.

`PanicEffectChecking` [PARTIAL, PANIC.md P3-P5] reads the sets the
barrier solved (EffectPropagation: one PanicWalk per body, a fixpoint over
every bare-`panic` function and closure of the graph) and walks each body
again keeping its sites. Each site's leftover (what no enclosing `try`
arm discharges) must be in its body's set: a body with no `panic` lets
nothing leave (SC001E naming every unhandled type, with the edits "mark it
`panic`" and "wrap the call in `try ... catch => crash!()`"); a declared
`panic(E1, E2)` lets only those leave (SC001E, edit: add the type to the
list); `main` and a script's top level let nothing leave and cannot be
`panic`; a field's or parameter's default lets nothing leave; a global's
or static field's initializer holds no panicking site and no `try`
(§4.5). A call is anything X resolved to a function: a call, a
constructor, a user operator (`resolved_op`), a `for` loop's `op in`. A
set that cannot be known (a callee in a fid that stopped before Typed, an
undefined bare-`panic` prototype, a gated callee) adds nothing. Also: `panic`
with `-> !`; `panic` on what runs with no call written (a destructor, a
transfer or default constructor, an `@implicit` conversion, `op panic`);
each panicked, declared or caught type must be a movable, complete value
type (§1.5); and SC116E for a generic, generator or `async` `panic`
function or closure and for every panicking site in such a body. It
stamps `PanicStmt::repanic` on a `panic e` of a catch binding (§3.4).
A `finally` whose previous sibling in its block is a `try` / `catch` is
SC001W: it is the standalone `finally`, run when the block exits, not
when the `try` finishes (PANIC.md §3.3).
The declared-set rules (P4): a bare `panic` on a `fn` type, an interface
requirement, a virtual base method or a closure is SC001E (edit: write the
inferred set where there is a body); an override's set within the base
method's and a conformer's within the requirement's (declared rows,
`ConformanceRow::reqs`); a bare-`panic` function used as a value is
SC001E (its value type carries only a declared set); and, building a
library (`--shared`), an inferred set on a `pub` function is SC001W.
The `try` rules (P5): each `try`'s body set is recorded on the node
(`TryCatchStmt::reach` / `TryCatchExpr::reach`); an arm whose type is not
in it is SC001W with a remove edit and marked `is_dead` for PanicLowering
(a C++ type outside the set is a C++ exception arm, never dead, marked
`is_cxx`, and SC001E with a remove edit in a build without C++ exceptions,
SemaOptions::cxx_exceptions -- LangOptions::cxx_exceptions, the rule
FlagTranslator passes to clang); a second
arm for one type is SC001E. Arms match exact types: no subtyping. An arm
after a bare `catch` is ArmOrderCheck's (V) SC001E in the statement form
and the parser's S054E in the expression form. An expression arm may be
`=> return v` / `=> break` / `=> continue` (a StmtExpr marked `is_jump`,
typed `!`).
`op panic`'s own signature (`const self`, `-> string`) is
OperatorSignatureCheck's, beside the other operator rules.

`ReturnPathCheck` [DONE] is structural, not a CFG: SC104 when a
value-returning body can reach its closing brace, SC105 for `-> !`. After X
because a call ends a path when its type is `!`; after PatternChecking
because a `match` ends one only when `is_exhaustive` and every arm does.
Unknowns (recovery nodes, `inline` blocks, `jump!`, a non-exhaustive match,
already SC120E) count as ending the path.

`ControlFlowAnalysis` [DONE] is the unreachable-code warning, SC003W: one
per run of statements after one that ends the path, up to the block's end
or a `label!` (a `jump!` target; a label nested in the run ends it too).
The divergence rule is ReturnPathCheck's, shared as `FallThrough`
(`Sema/Check/ControlFlowAnalysis.k`), with unknowns the other way round:
they fall through, so code that may run is never called dead. Same
REQUIRES as ReturnPathCheck; before every lowering, so it sees only user
code. Dead match arms stay PatternChecking's SC121E. It replaced the
lexical V pass TerminatorCheck, which could not see `-> !` calls. A
script's top level (ScriptRules::is_script) is walked as one block, since
it is main's body: a region there is a contiguous run of code items, so a
declaration between them (a function, a type, a binding with a constant
initializer) is never in it and never in its fix-it, and a deferred
binding is code. Nothing ScriptLowering mints can warn: it runs after.

JumpLabelCheck's script rule (`run_script_jumps`) [DONE]: in a script
(ScriptRules::is_script), a top-level `jump!` whose path crosses the line
of a deferred binding, forward or back, is SC001E at the jump, with notes
at the binding and the label (SCRIPT.md 2.7). Its frame rules stay in V;
this half runs after X, because which bindings defer is
ScriptRules::defers, a question of typed, ConstEval-folded initializers,
and the same predicate ScriptLowering moves lines by. Every user
`label!`/`jump!` is still FeatureGateCheck's SC116E as well.

`OperatorSignatureCheck` [DONE] runs BEFORE X, because X's derived
operators and compound-assignment pairing assume the shapes it rejects:
`===` and `=` declared at all (neither is overloadable), both halves of a
compound pair (`op +=` AND `op +`), a default argument on an operator, a
comparison not returning `bool`, a compound assignment with a result,
`op ->` not returning a safe `*T` / `*const T` (SC113E), `[]`
returning nothing or `unsafe *T` (SC114E), and a member-only
operator (`op as`, ...) in an extension.
The place/value rule (`OperatorFacts::is_place`): `[]`
returning a safe `*T` / `*const T` is a PLACE; any other result makes it a
VALUE operator (`.*` and `->*` are not overloadable; the parser rejects
the declaration), and a pointer returned by value is not expressible.
`type_subscript` on a Kairo place `op []` yields the POINTEE of the result
as an lvalue (const if the pointer was), not the pointer, and `&a[i]`
takes the pointer back; on a value `op []` it yields the result as an
rvalue, so `&a[0..1]` is the ordinary address-of-rvalue error. A foreign
`operator[]` is taken as declared, an lvalue.

`ConstraintExtraction` partitions each decl's canonical `requires` into
conformance constraints vs value predicates and writes the result to
`sc->bounds` keyed by owner decl [DECIDED, MISSING] -- the bound table
ChainBinding's dependent path and ConformanceChecking read.

    [DECIDED] TypeCycleCheck / LayoutPass treat a `RecordType::decl` that
    is `is_instance() && !instantiated` as "size unknown until M2", never
    as empty. The by-value EDGE question ("does `Box<X>` hold X by
    value?") is not the size question: it is answered from the PATTERN's
    fields, which exist before M2, so `class U { var b: Box<U> }` and
    `struct A { var t: (i32, A) }` (a tuple is the TupleN record) are
    reported today (type_cycle_generic.k, type_cycle_array_tuple.k).
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
    NullnessFlow.k       component: the nullness analysis (NULLABLE.md §3-§5),
                         which the mixins report into and ask at each use;
                         also the null-test classifier NullTestLowering uses
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

Plus facts on operator and call nodes that are slots, not nodes:
`resolved_op`/`op_via_free` on Binary/Unary/Assign/Subscript/`TypeCastExpr`
(the user operator overload resolution selected);
`BinaryOperatorExpr::op_rewrite` (a comparison derived from `op ==` as
`!(==)` or from `op <=>` as `(<=>) <op> 0`, so OperatorLowering never looks
an operator up again); `BinaryOperatorExpr::tag_eq` (`==`/`!=` on two values
of one ADT enum that declares no `op ==`, `resolved_op` null: OperatorLowering
compares the two `adt_tag_field`s); `op_instance` on Binary/Unary/Assign and
`CallExpr::instance` (the registry entry of a GENERIC callee's instance,
`*InstanceEntry` stored as `*void`, which EmitIR spells the call's template
arguments from and EmitPlan homes); and `CallExpr::arg_map`/`pack_len`
(argument placement over `f->params`, `self` included, -1 = default, -2 =
the bound receiver in slot 0, which is no argument and has no default); and
`CallExpr::ctor_decl` (a constructor call's selected constructor: the callee
names the TYPE, so nothing else records which ctor `arg_map` is parallel
to). `Lower/` reads them; codegen reads the instance slots and `ctor_decl`.

And the narrowed-read mark (NULLABLE.md §4): `NamedIdentExpr::narrowed_from`
/ `ChainExpr::Step::narrowed_from`, the `T?` of a read the nullness
analysis proved non-null and typed `T` instead. The one place besides the
`&` marker where a memoized `type_` is rewritten after the node was typed:
by the CONSUMER that needs the value (an operator, `.` / `->`, a
conversion to `T`, a call taking `T`), never by the use itself, so a use
that does not read the value keeps `T?`. NarrowedAccessLowering reads it.

And facts on an enum variant construction, which X checks and does not
build: `variant_decl` on the node the construction was written as -- the
`NamedInitializerExpr` of `E::V { .. }` / `.V { .. }` / `.V`, or the
`ChainExpr` / `NamedIdentExpr` of a payload-less ADT variant named as a value
(`Opt::None`) -- holding the pattern enum's own `EnumVariantDecl`; and
`InitField::field_decl` on each of its fields, the payload `FieldDecl` the
field fills. Written only once every field matched exactly once. A plain
enum's variant gets the slot only when written `.V`: `Dir::North` is already
the value it names. A head (`Shape::Rect` before its braces, a pattern's
head) is not a construction and gets nothing (`ExprTyper::variant_head`).
`VariantInitLowering` reads both and builds the node; `variant_decl_of` is
the one reader of the three slots.

**Four terminal states per expression.** typed (`type_` set); poisoned
(diagnosed, `type_` null); unknown (`IsInstantiationDependent` set,
`type_` null, not poisoned: dependent, foreign, or a hole a later pass
owns -- consumers skip checks on it); type/module-denoting (recorded in the
typer's side tables; only a callee or initializer head may read it).

An expression is unknown only when its type cannot be NAMED. A dependent
type that can be named is a type: `Cell<T>{ x: v, n: 0 }` in a generic body
is typed `Cell<T>` (IsInstantiationDependent may stay set -- the type does
mention T), its fields are looked up on Cell's decl and each value is typed
against the field read through the head's args (`member_through`), with the
convertibility check left to the instance when either side is dependent.
Unknown is reserved for a head with no record behind it: an unbounded
`T::Inner`, a duck-typed `T`. Codegen ICEs on an untyped initializer.

The call form gets the same treatment: `Box<T>(p)` in a generic body is
typed `Box<T>`, an rvalue. Its constructors are the pattern's, resolved by
`OverloadResolution::resolve_deferred`: each parameter is read through the
call's record arguments (`member_through`); one still dependent, or a
dependent argument, is viable for anything and unranked (`assumed`), and a
concrete pair ranks -- and errors -- as in any call. An Exact candidate that
assumed nothing beats an assumed one, which is what keeps every generic
record's `@move fn R(self, other: Self)` from making its other constructors
ambiguous. A unique winner writes `ctor_decl` and `arg_map` exactly as a
concrete call does. Codegen ICEs on an untyped constructor call.

**Known gap: a tie through an assumed candidate.** When the best candidates
tie only because one was assumed (or a lone assumed winner has a viable
rival), the outcome is `Deferred`: no diagnostic, the call typed,
`ctor_decl` null, and EmitIR's `Rec<T>(args)` lets clang pick the
constructor per instance -- so an ambiguity there surfaces as a clang error
on the instance, not a Kairo one at the definition. Closes when the bounded
regime gives each parameter enough to rank.

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

One BOUNDARY rung (`abi_widen`), Converted, asked only for an argument to
an imported callee after the lattice said None (`_rank_arg`, and
CallTyping's post-selection re-check): integer widening where
`usize`/`isize` are the width RANGE [32, 64] over every supported target
and a fixed-width integer is [N, N]. S -> D is accepted iff max(S) <=
min(D) (strict for uN -> iM; iN -> uM never), so `u32` reaches a `size_t`
parameter without `as` and `usize -> u64` holds, but `u32 -> isize` and
`u64 -> usize` do not. The floor is 32 unless the target's pointer width
is narrower (a 16-bit target refuses `u32 -> usize`); otherwise the target
is never read, so §4's portability holds across every 32/64-bit triple.
Fixed-width pairs stay the lattice's alone. Off under `-fno-implicit-conv`.
Kairo signatures, assignments and joins never see it.

Two USER rungs sit after the lattice, both Converted, both closed to
`join` and `unify_operands` (`implicit_builtin`) and to the recursion
under `T -> U?`, so at most one applies per sequence and an arm or operand
is never converted by one:

- `[T; N] -> [T;]` (`array_views_as`): a view, nothing copied; a const
  array views only as `[const T;]`. The one container conversion the
  compiler owns, because an array has no body to declare an `op as` in.
  EmitIR spells it as `Slice<T>(&(a)[0], N)` wherever a value is emitted
  against a record (`_array_view`). `a[i..j]` on an array is the same view:
  MemberTyping resolves Slice's range `op []` on it and OperatorLowering
  wraps the base in an `ImplicitBoundaryCastExpr`. HOLE: a `const`
  binding's constness is not in its type, so a const array bound to
  `[T;]` is caught by clang, not here; and a view of a local that escapes
  (returned, stored) is not diagnosed -- AMT's escape clause, as for a
  retained slice argument.
- `@implicit fn op as (self) -> T` (`implicit_op`): a member `op as`
  carrying the attribute (`OperatorFacts::is_implicit_conv`, probed in the
  decl's own imm table) whose result is EXACTLY the target, read through
  the receiver's generic arguments (`_same_through`). No chaining. Nothing
  is inserted into the tree: `op as` is emitted as a non-explicit C++
  `operator T`, so clang applies what Sema allowed. OperatorSignatureCheck
  rejects `@implicit` anywhere else (SC115E). `Vector`'s `-> [T;]` in
  Lib/builtin is one: `[T] -> [T;]` is library, not compiler.

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
A literal SequenceLowering hoists into a `__kairo_arg` local is marked
Extended there for the same reason: the local is a `var`, and the statement
expression's block is the scope its backing array lives in.

**Dotted variants** (`ControlTyping::type_named_init`). `.V` and `.V { .. }`
take their enum from the expected type, as a `.V` pattern takes it from the
scrutinee: a reference, cv and a nullable are looked through. No expected
type, one that is not an enum, or an enum with no variant `V` is SC123E; a
bare generic parameter is unknown with no diagnostic, as an initializer whose
head is one is. In argument position `.V` is deferred like a literal
(`LitKind::Variant`, the name in `ArgInfo::lit_name`): Exact against a
parameter whose enum has a variant of that name, nothing otherwise, and typed
against the parameter after selection. A dependent parameter deduces nothing
from it: `f(.A)` against `fn <T> f(x: T)` has no viable candidate.

**Argument order.** Arguments are evaluated left to right, whatever the C++
compiler would do with them. SequenceLowering writes the order into the
tree: a call with two or more side-effecting operands (the receiver of
`x.m(...)` is operand zero) becomes a statement expression that binds each
of them to a `__kairo_arg` local first. A call whose result is an lvalue (an
imported `T&` return) or a record value keeps C++'s order for now -- a
statement expression yields a prvalue, which would change the category or
force a copy the type may not have. Primitive operators are not calls and
are not covered.

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
Specializations are skipped (paired later). A one-type pack ranks each
argument against its element. A TYPE pack deduces one element per argument,
its type by value (a literal its default), into `Deduction::packs`, opened
even for an empty run; the instance carries the elements flat, at the
pack's position. Its elements cannot be written as explicit generic
arguments yet (not viable, with that reason). A default is looked for across the WHOLE redecl
chain (`TypeUtil::param_default`): defaults accumulate over redeclarations,
and the link judged need not be the one that wrote it. An imported C++
callee can only omit TRAILING defaults (clang applies them by omission); a
named argument that fills a parameter after an unfilled defaulted one is
SC107E. An extension member's own parameters are the receiver's
(`Deduction::bind_from_extension`, after the receiver is judged, before
placement); once `seeded`, a dependent parameter is ranked as its
SUBSTITUTED type, so a literal takes it and an argument converts to it
rather than re-deducing it, and an extension whose parameters are still
unbound is not viable. Diagnostics: no viable (capped candidate notes),
ambiguous, not callable.

**Deduction** (`ArgumentDeduction.k`). Structural unify of the param's
canonical against the arg's, binding `(owner, index)`; conflicts fail,
there is no common-type search. Top level may succeed through the implicit
relation (Converted); inside a structure exact or nothing. `substitute`
rebuilds through the store and goes through the registry for a concrete
record. `member_through(recv, mt)` reads a member type through the
receiver's args. `replace_self(t, I, T)` reads an interface member through
a bound (`-> Self` is `T`). `bind_from_extension(f, recv)` seeds a generic
extension's parameters from the receiver before any argument is ranked:
the extension's target is UNIFIED with the receiver, so `extend <T>
Vec<Box<T>>` binds what it names and a receiver it does not match makes
the candidate non-viable. No receiver, or a dependent one, binds nothing
(`Vec::m(v)` deduces from its `self` argument). It sets `seeded`.
A qualified requirement call (`Container<i32>::get(b, 0)`) seeds the same
way from its qualifier: `declaring_instance(f, Q)` is the instance of the
requirement's declaring interface Q names (through the composed list's
`Requirement::source` when Q derives it), and its arguments bind the
interface's parameters before any argument is ranked. In a GENERIC
interface `Self` is `I<T...>` over its own parameters, so the Self rule
(`through_receiver`) also takes that spelling, and CallTyping applies it
before the substitution for a concrete receiver: substituted first, `I<T>`
reads `I<i32>` and is no longer recognizable as Self.

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
`??` on `T?` joins the inner with the right; `===` needs a nullable
operand and is not overloadable, but the `==` its expansion runs on the
unwrapped values (NULLABLE.md 2.3) is resolved here like any `==` and
recorded on the `===` node for CoalesceLowering to carry over. `^^` on
primitives calls the `pow` lang item and needs an integer exponent.
Non-primitives search the LEFT operand's members and extensions
under `op_name`, plus free operator functions found by ADL in the modules of
EITHER operand's type (`MemberLookup::associated_scopes`: the enclosing
modules up to, not including, the TU; pointers/refs/nullables peel; generic
args recurse), plus -- for operators only -- the FILE scope the record was
declared in (`MemberLookup::declaring_scope`): a free `op *` beside a
file-scope type is otherwise unreachable from every file, its own included.
A comparison the type does not declare is derived: `!=` from `op ==`,
`<`/`<=`/`>`/`>=` from `op <=>` (C++20's rewritten candidates, minus the
reversed ones), and `==`/`!=` from `op <=>` when no `op ==` answers (Kairo's
rule, not C++'s: never on an imported record), recorded in `op_rewrite`. A
comparison the type declares beside an `op <=>` wins every use and is
warned about as shadowing the derived one (OperatorSignatureCheck, SC001W
for now). `==`/`!=` on two values of one ADT
enum -- one canonical type, so one instance of a generic enum, never a
nullable -- with no `op ==` found compares variants, not payloads: X sets
`tag_eq` and binds nothing, and OperatorLowering writes the builtin
`a.<tag> == b.<tag>` through `EnumDecl::adt_tag_field`. A nullable ADT
operand keeps builtin equality; two instances of one generic enum have no
`==`. Members and frees rank in ONE set
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
An asserting downcast is not a panic: it crashes on a wrong type
(PANIC.md §5, P9) and joins no panic set. `panic_sites()` collects them
for that check; PanicEffectChecking does not read it.

Into a CLOSED plain enum (every plain enum not `@open`; the parser stamps
`EnumDecl::is_open`, TypeResolve ORs it over a forward declaration's chain,
DeclImport sets it on every imported enum) the value must be a variant's.
A ConstEval-constant operand is checked at once (SC001E placeholder, fix-it
`@open` on an enum this file declares); when the enum is declared below the
cast its values are not written yet, and run() checks the deferred cast
after the walk. Any other operand sets `TypeCastExpr::enum_check` (the
enum), and OperatorLowering wraps the operand: `({ var t = v; if <miss> {
unwrap_failed(m, n) } t })`, `<miss>` being `t >= N` (`|| t < 0` signed)
for values `0..N-1`, else a `!=` per variant -- a crash (PANIC.md §2.8),
through the UnwrapFailed lang item `unwrap!` aborts with. A closed enum's
values past a dense set are its niche (EnumNiche); `@open` gives up both.

The asserting downcast `p as *D` (D below p's polymorphic pointee) sets
`TypeCastExpr::asserting_downcast` and always warns (SC001W placeholder,
fix-it appending `?`). OperatorLowering expands it: `({ var s = p; var d =
s as *D [dynamic_only]; if s && !d { unwrap_failed(m, n) } d })`, the same
crash entry, the message naming the cast, both types and the site
(PANIC.md §5). A dependent pointee stays SC091E for the asserting form.
Every crash message is built whole by `LowerSynth::crash_call`; the
runtime (Lib/rt/crash.c) appends the newline.

**Control** (`ControlTyping.k`). if/match/try as expressions join their
arms (`Conversion::join`: identical, one-way W, or Never on one side);
every arm must then convert to the join. Closures type as their fn-pointer
canonical; params must be annotated; return declared or inferred through
a frame. `a..b` -> `Range<elem>`; `await` on `Future<T>` -> `T`; `spawn`/
`thread` -> `Future<T>`; `sizeof`/`alignof` -> usize; `typeof x` is
type-denoting; `unsafe e` bumps the unsafe depth; `delete p` needs a
pointer. `({ s...; e })` types its leading statements in order, then `e`
against the expected type; the result is a prvalue of `e`'s type with
references and top-level cv dropped, and a fixed array is an error. Named initializer: fields by name in the record's table, values
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
the value's type until ContextLowering. `yield e` is typed against the
function's `yield T` (StmtTyping). A parameter default is typed against its parameter, and
may not refer to another parameter or `self` (SC106E: a default is evaluated
by a nullary thunk, so it has nothing to read them from) nor be a slice
literal (SC082E: the thunk would return a view of a dead array).
An enum discriminant is typed against the underlying type (`u32` when
none is written), the variants of its own enum reading as that integer;
then `ConstEval` (Sema/Check) evaluates it, exactly, into
`EnumVariantDecl::value`; `~x` alone is taken in the type of `x` (so `~0`
is the underlying type's all-ones value), the other operators on the
infinite two's complement form. A variant without one is the previous value plus
one, the first 0, so every variant of a Kairo enum gets a value, an ADT's
being its position. Only variants ABOVE the one being defined evaluate.
SC128E when the discriminant does not evaluate or its value does not fit
the underlying type; an imported C++ enum's values are clang's, not written.
SC130E when a variant's value repeats one above it (a closed-enum match's
switch would have two case labels with one value); a variant whose value
failed takes no part, and neither ADTs nor imported C++ enums are checked.

**What X does NOT do**: ADL through the global namespace (a type at TU
scope associates no scope, by design; see `_enclosing_modules`); pack deduction and
ranking; exhaustiveness and dead arms (PatternChecking, after X). X DOES
type patterns (PatternTyping): it classifies each head N bound (variant,
record type, or `const` / `eval` constant) into `Pattern::resolved_decl`,
maps payload subpatterns to fields (names first, then positions) into
`Pattern::field_decl`, and types every binder;
const-correctness, including assignment to const and const-cast validity
beyond "adds const" (ConstChecking); panic effects (PanicEffectChecking,
past the Typed barrier); access control (AccessCheck); `yield` vs `yield T`;
the context-binding protocol; the `: type` gate (FlagGates: an error
without -fduck-generics).

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
§6). The order is fixed, and owned by `Sema.k::_stage_lowerings`; this is
exactly what it runs today, in order:

    VariantInitLowering -> EnumLayoutLowering -> ExprBodyDesugar ->
    WhereDispatchLowering ->
    FieldInitLowering -> CtorInitLowering -> CopyMoveLowering (moves) ->
    ScriptLowering -> PanicLowering -> FinallyLowering -> TupleLowering ->
    CoalesceLowering -> NullTestLowering -> NarrowedAccessLowering ->
    NullableTypeLowering ->
    OperatorLowering -> FStringLowering -> CallLowering -> IterLowering ->
    RangeLowering -> MatchLowering -> LabelLowering -> ExtensionLowering ->
    SequenceLowering -> ListLiteralLowering -> StringLowering

PatternCompilation, which builds the decision tree MatchLowering renders,
is not a lowering: it runs last in the checks (§2.8). Every pass walks a
closure's body as it walks a function's (the ASTWriter descends into
`ClosureExpr`), so a closure's body is lowered like any other.
ExprBodyDesugar also turns a closure's expression body into a block
(`return e`, or `e;` when its resolved return type is `void` / `!`).
Still to come, each a
stub file or a `TODO(sema)` in `Sema.k`: UsingDeclSynthesis,
TypeQueryLowering,
CopyMoveLowering (copies). Generators need no lowering (a C++ coroutine,
spelled by EmitIR), and destruction none (C++ destroys locals at scope
exit). Sugar first, control flow
second, lifecycle last. Every pass is an ASTWriter; a node a pass owns that reaches
codegen is an ICE naming the pass. NullableTypeLowering is the exception
on types: it rewrites no type in the tree, it fills each canonical `T?`'s
`lowered` slot with its `::builtin::Nullable<T>` record (NULLABLE.md 1.1),
and only a `T?` with no record is the ICE.

The nullable block (NULLABLE.md §5), four passes in this order, after
TupleLowering and before OperatorLowering. Every one but the last still
sees `NullableType` on every expression it reads:

- CoalesceLowering [DONE]: `x ?? y`, `x?.m` / `x?.f(args)` / `?->`,
  `unwrap!(x)`, `a === b`, and a `match` on a `T?` (whose `case null` is
  answered before the match) become the if-expressions / statements of
  NULLABLE.md 2.3-2.6 and 3.6: typed `x?` tests and reads marked narrowed,
  for the two passes after it. A non-place operand is bound once
  (`__kairo_coalK` / `__kairo_safeK` / `__kairo_unwrapK`). `===`'s `==`
  carries the operator typing recorded on the `===`, for OperatorLowering.
- NullTestLowering [DONE]: every null test (`x?`, `!x?`, `x == null` and
  the other spellings, via `null_test_of`) becomes `x.is_null()` /
  `!x.is_null()`; a compared `null` literal is dropped with it.
- NarrowedAccessLowering [DONE]: every read the nullness analysis (or a
  CoalesceLowering expansion) marked narrowed becomes `x.__value()`, the
  unchecked accessor, an lvalue.
- NullableTypeLowering [DONE]: fills each canonical `T?`'s `lowered` slot
  with its `::builtin::Nullable<T>` record (below); `null` becomes that
  record's null.

WhereDispatchLowering [DONE]: each group in `where_groups` becomes one
function. The lead keeps its identity (every call names it) and becomes
the dispatcher, with fresh parameters: `if g0 { return K0(args) } ...
return Kn(args)`, guards in dispatch order, each retargeted by position to
the fresh parameters, the last call untested. Every member hands its
parameters and body to a minted `priv` candidate
`__kairo_where_<name>_<k>` (k in source order, LowerTargets), so no body
is rewritten; a non-lead member leaves the tree. A forwarded by-value
MOVE parameter is recorded in `move_sites` for CopyMoveLowering. After
ExprBodyDesugar (bodies are blocks), before every other body rewrite.

MatchLowering [PARTIAL]: every match becomes labels, gotos and switches
over a once-evaluated scrutinee, rendering PatternCompilation's tree (a
match left on the value of a `T?` by CoalesceLowering is an ordinary one
by then). A match that tests a dependent column in a generic body gets no
tree and reaches EmitIR (ticketed). An exhaustive switch over an ADT's tag
defaults to `__builtin_unreachable()` (CodeGenOptions::adt_tag_policy; a
trap under `--hardening=enum-tags`), and so does a closed plain enum's
(USER 2026-10-27: its `as` is checked, so it holds no undeclared value);
an `@open` or imported enum's and an integer's default to UnmatchedPolicy; an ADT with no tag (niche-filled) is an `if` chain of
EnumLayoutQuery::variant_test, the last variant untested.
LabelLowering [DONE]: `break L` / `continue L` become gotos.

EnumLayoutLowering [DONE]. Every ADT pattern gets one StructDecl,
`EnumDecl::adt_layout`: a tag enum (`__kairo_Tag`, the variants by name and
in order, so a tag is a variant's position), one payload struct per variant
with a payload (`is_adt_payload`; its fields ARE that variant's payload
FieldDecls), the tag field (`adt_tag_field`), an anonymous union with one
member per payload (`EnumVariantDecl::adt_member`), five flags when the enum
is generic, and FunctionDecls with no Kairo body marked `adt_role` /
`adt_form`: a constructor per variant, the special members (all three forms
of each when generic, the one its lifecycle facts select otherwise), and the
private destroy / construct-from helpers. Every minted decl's semantic_dc is
the EnumDecl. Nothing is retargeted: RecordTypes keep naming the enum, and
codegen reaches the record only through `adt_layout`. A non-generic ADT
whose facts are Unknown (a payload that is a generic instance) is rejected
first by FeatureGateCheck (SC116E), so the pass's ICE on one is an invariant.

A pack-expanded variant `Err { e: E }...` (PANIC.md §1.2; always the last
variant, its pack fields typed bare `E`) is one constructor per element of
the instance's pack. Its payload struct is a C++ template over the element
(`StructDecl::adt_pack_param`), its union member a `__kairo_pu<P<E>...>`
(the preamble's recursive union), its constructor `(vt<p>, vt<K>, f)`, and
its tag the variant's plus K. Every index EnumLayoutQuery takes is EXPANDED
(`adt_variant_at` / `adt_expansion_at`): a variant's position, element k of
the pack variant at position p being p + k, which is also its tag; a payload
read carries K on its chain step (`Step::pack_index`). An enum whose pack is
expanded has its pack args deduplicated where the type is formed
(`decl_dedup_pack_args`, in CanonicalTypes::record and the registry), so
equal elements are one variant; a `PackSetOrder` the driver installs in
both also fixes the ORDER for a lang item that wants one (the Panic item
sorts its set by type id, Sema/Type/PanicSets.k, PANIC.md §1.3). Under
type-id tags (AdtLayoutKnobs, the Panic item) element k's tag is its
type's id, not p + k (`EnumLayoutQuery::tag_value(t, en, index)` takes
the value's type for it). Construction and patterns pick the element
by payload type (`VariadicEnum`; ControlTyping / PatternTyping record
`variant_pack` / `Pattern::pack_index`); at a dependent type either is
SC116E until M2. No niche: the tag niche is per instance, so none is
promised.

The tag is the enum's `derives` type, else the narrowest of u8 / u16 that
holds the variants (a too-narrow `derives` is R001E in TypeResolve); tags
stay dense `0..N-1`. A variant whose fields are all trivially copied and
destroyed is built through one field constructor (`EnumVariantDecl::
adt_ctor`: Fields; a generic ADT has Both, the site choosing by
`VariantInitExpr::field_ctor`), every other through the lambda one. An ADT
with one payload variant of one field beside dataless ones is niche-shaped
(`adt_niche_shape`): laid out with no tag when the field's niche
(`EnumLayoutQuery::niche_of`) covers the dataless variants and the field is
trivial -- decided here for a non-generic one (`adt_niche`), by C++ per
instance for a generic one (a constrained partial specialization), which
Sema predicts and `EnumLayoutQuery::sweep` records on each InstanceEntry
for codegen's static_asserts. Every reader and test of an ADT value goes
through `EnumLayoutQuery` (tag_read, variant_test, payload_ref, field_ref,
same_variant): MatchLowering and OperatorLowering never spell the layout.
A generic ADT, and a niche-filled one, also get `__kairo_which()`
(AdtRole::Which), which the query uses where it cannot predict the
instance's layout. `__builtin_niche_of<T>()` (the NicheOf lang item) is
answered here, as a literal. A non-generic, non-niche ADT whose payload
fields are all builtins, pointers or plain enums keeps its tag in the
payloads' common prefix (`adt_tag_member` / `adt_prefix_tag`): each payload
struct starts with the tag, the union's first member holds only it, and
the query reads it there.

CopyMoveLowering [PARTIAL]. The moves only, and early: every site
MoveCheck recorded in `SemaContext::move_sites` -- a MOVE value passed by
value or to a C++ `T&&`, initializing a variable, assigned, or returned
when it is not a bare local -- becomes `e as T&&`, which EmitIR spells
`static_cast<T&&>(e)`. Kairo has no std::move; the type decides that a
transfer moves, and C++ only moves an lvalue that is cast. MoveCheck is
the only decider, so the cast and the use-after-move check agree. It runs
before every pass that rebuilds an expression, so each recorded node is
still in the tree; SequenceLowering leaves the cast in place (a cast of a
name is pure). Choosing a @copy constructor stays with the later slot.

ScriptLowering [DONE] (SCRIPT.md). A script -- the program's root file
(`SemaContext::script_root`, set by the driver for each command-line
input, never for an import or a `.k` a C++ input includes) with top-level
statements and no `fn main` -- gets a synthesized `fn main() -> i32` whose
body is those statements, in order, ending in `return 0`. Every top-level
binding stays a global. One whose initializer is not constant
(ScriptRules::defers, the one answer to which lines are deferred, which
JumpLabelCheck's script rule and ControlFlowAnalysis share) is DEFERRED: its storage becomes `T?` starting null, main assigns
it at its line, and main's first statement is a `finally` that nulls the
deferred globals in reverse order. A read in main after the line is marked
narrowed; one at or before it, or a direct call from main that reads it on
every path, is SC001E; a read anywhere else is the `unwrap!` place form,
aborting with "script variable 'g' used before its line ran". A top-level
`return` returns from main (bare: 0; with a value: an integer exit
status). Statements in a file that is not the root, or beside `fn main`,
are SC001E. After CopyMoveLowering, whose `T&&` cast on a moved
initializer moves into main with it; before FinallyLowering, which lowers
the teardown, and before the nullable block, which lowers the tests and
narrowed reads it builds. Its record of the first statement
(`SemaContext::script_at`) is how the driver rejects two scripts in one
link. EmitIR's
ICE on a top-level statement means this pass did not run.

PanicLowering [DONE, P6] (PANIC.md §4). A panic is a returned value. A
function whose final set is not empty returns `Panic<T, E...>`, formed with
PanicSets::form and recorded as `FunctionDecl::panic_result` (an
override's is its base method's, a conforming method's its interface
requirement's; a closure's on the ClosureExpr, a `fn`
type's on its canonical node); `return_type` stays T, because an
importer's X reads it after this TU lowered. `return x` builds Ok, `panic
X` builds the Err with its site id; a call that may panic is held in a
statement expression where it sat (`var p = f(); if !ok(p) { <deliver> }
p.value`), so evaluation order and short circuits are the tree's; a tail
`return g()` forwards g's result whole. An error goes to the innermost
target: the function's return, or a `try`'s raw-storage slot and a jump to
its dispatch, which moves it into a local first; `catch e: E` is one tag
compare. A `try` whose body is one statement that is, assigns, returns or
binds its one site reads that call's result with no slot. C++ with no Kairo
spelling is a PanicOpExpr (`fwd`, slot put / take) and a `raw_slot` local.
A `try` with C++ exception arms (`is_cxx`, P7) keeps them as a C++ `try`:
the lowered body goes in a TryCatchStmt marked `cxx` whose arms are those
arms (EmitIR writes `try { } catch (T& e) { }`), the panic dispatch after
it (always the slot form, so no panic arm sits inside the C++ `try`); the
function stays noexcept, so an exception no arm matches terminates at its
boundary. In that body a value that can throw is bound to a local before
an ADT payload is built from it (codegen builds payloads in noexcept
lambdas). `panic e` of a C++ arm's binding panics a copy of it.
After ScriptLowering (a script's main is an ordinary body) and
CopyMoveLowering; before FinallyLowering (every jump and return made here
is an ordinary exit to it), LabelLowering, CallLowering and SequenceLowering
(which orders a held call's arguments: a panic result is the one record
result it sequences).

FinallyLowering [DONE]. `finally { body }` becomes a StructDecl declared in
the function body whose `op delete` is the body, plus a local of it where
the statement stood (`__kairo_FinK` / `__kairo_finK`, LangItems). C++'s
rule for locals is the doc's `finally`: destroyed at the block's end, every
exit, LIFO with the block's other locals. Captures (FreeVarScan,
CaptureAnalysis.k) are the free automatic locals and the enclosing
function's parameters, every one by address, in first-use order; the
enclosing `self` is the `__kairo_owner` pointer field. Each use in the body
is rewritten to `(*self.<field>)`. Statics and globals are not captured.
EmitIR emits the record in place (`_local_record`), CXXSpell names a
function-scope record by leaf, EmitPlan never admits one. A `finally` in a
closure is the same record, declared in the lambda's body and homed in
the enclosing function; a closure's parameters are captured like the
function's, and a binding the closure holds by pointer is reached through
that pointer (the guard's field points at it).

FieldInitLowering [DONE]. A class or struct field's initializer becomes
its C++ default member initializer. A constant (an integer ConstEval
folds and that fits the field, `true` / `false` on a bool, `&null` on a
raw pointer) is recorded on the field (`FieldDecl::init_fold`, the value
in `init_neg` / `init_mag`) and spelled in the class. Anything else
becomes `fn __kairo_init_<f>(self) -> T { return <init> }`
(`LowerTargets::field_init_thunk`), appended to the record's methods and
stamped as `FieldDecl::init_thunk`, and the default calls it. Either way
`init` is null afterwards (MOVED into the thunk). The thunk's body goes
out of line like every user-written body (IMPORTS.md invariant 12). It is
a method, so a bare member the default names (it keeps the type body's
scope) is read through `this`; InitCheck has made sure that member is
built by then. A STATIC field folds or thunks the same way, but its thunk
takes no `self` (a static member: there is no object), and the value is
its out-of-line definition's, not a default member initializer
(CODEGEN.md §5). An array field's list literal is lowered one ELEMENT at
a time, since no C++ function returns an array: a thunk per element,
`__kairo_init<i>_<f>` (`LowerTargets::field_init_elem_thunk`), stamped in
order as `FieldDecl::init_elems` (`init_fold` Elems), and the default is
`= {__kairo_init0_f(), ...}`. Eval fields and every other array
initializer keep `init`; FeatureGateCheck has rejected them.

CtorInitLowering [DONE]. A constructor CtorInitCheck split has its body
cut into exactly two blocks, `{ {S_pre} {S_post} }`, at `ci_split`, and
`ci_cut` set; nothing is renamed or minted, so Sema's view of the record
(its member lists, overload sets) is unchanged. Right after
FieldInitLowering, because the cut is a statement COUNT and every later
pass may insert statements (each lands inside its own half).

CallLowering [DONE]. After it every call is one positional argument list in
parameter order; `NamedArgExpr` is gone and `arg_map` is empty. A default
becomes a nullary thunk (`LowerTargets::default_thunk`), one per entity and
parameter index, stamped as `ParamDecl::default_thunk` on that index in
every link of the redecl chain, and spliced beside the declaring link; a
default written on an out-of-line definition becomes a member of the owner.
`default_val` is MOVED into the thunk, so it is null afterwards. Explicit
arguments evaluate left to right as written, whatever parameter they name;
defaults evaluate after them, in parameter order. A pack over one type is a
`Slice<E>` by value (`ParamDecl::pack_type`) over a backing array alive for
the call's full-expression; a TYPE pack (`fn <...T> f(...xs: T)`,
`param_is_type_pack`) is a C++ parameter pack, its run left one argument
per element. A call with an lvalue or record result keeps C++ order
(the documented SequenceLowering hole). Dependent calls are left as written
until M2.

IterLowering [PARTIAL]. X records each ranged `for`'s `iter_kind`,
`iter_elem` and, for a user `op in`, `iter_op`. A `for` over a type pack
(`IterKind::Pack`, its binding typed as the pack) is left for EmitIR, which
unrolls it as a fold, one lambda copy per element. The pass renders a block of
hidden locals and a `while` that advances before its body (so `continue`
needs no step). Done: `a..b`, `a..=b` (never computes past `hi`), Range
values (`inclusive` read at run time, never computes past `last`),
`[T; N]`, `[T;]`, user `op in (self) -> yield T`, and imported C++ ranges
([stmt.ranged]: member `begin()`/`end()`, else free ones by ADL). Only an
imported record takes the C++ protocol: `op in` is a Kairo type's one way to
be iterable, so a Kairo class's `begin()`/`end()` never route a `for`. For a C++
range X resolves both calls on the range's cv and types `__it != __end`,
`*__it`, `++__it` over two hidden locals it mints (RangedForStmt::cxx_*), so
the loop's operators are chosen like any expression's; IterLowering places
them and runs OperatorLowering over them, since they enter the tree after that
pass. A pointer iterator's `++` is minted typed (Kairo has no user `++` on
pointers). Binders: plain `x` copies, `*x` points at the element (at a
per-iteration copy over a range or a prvalue `*__it`); `(k, v)` binds the
tuple element once (a const reference when it is a stable lvalue, a copy
otherwise) and each binder off its fields. Not yet: Vector, set, map,
string, nullable binders.

RangeLowering. A range value is `Range<T>{.begin, .end, .inclusive}`; open
ranges are valid only as a subscript index (X), where `a..` and `..` are
`RangeFrom<T>{.begin}` (`..` is `RangeFrom<usize>{.begin = 0}`) and `..b` /
`..=b` are `RangeTo<T>{.end, .inclusive}`. A subscript's range reaches the
pass as an ordinary `op[]` argument (OperatorLowering ran first), so it is
lowered like any other range.

VariantInitLowering [DONE]. First, so X's variant facts are read on the
nodes X wrote them on and every later pass sees one node kind for a
construction. An ADT construction becomes a `VariantInitExpr`: the payload
in declaration order (what a C++ braced list runs), `source_order` the
position each field was written at (what Kairo runs), and the node's type --
the instance for a generic enum -- and category kept. SequenceLowering binds
the fields to locals when the two orders differ and a field has side
effects. A plain enum's `.V` becomes a `NamedIdentExpr` bound to the
enumerator and typed as the enum, which EmitIR spells as it spells
`Dir::North`. EmitIR spells a `VariantInitExpr` as a constructor of the
enum's layout record, which EnumLayoutLowering builds.

TupleLowering [DONE]. A tuple is its arity's record: `(A, B)` is
`Tuple2<A, B>`, a generic struct with fields `_0: T0, _1: T1`, no
constructor, no methods, MINTED on first use (`AST/Context/TupleRecords`,
one per arity per build, homed in the builtin root TU, in no table) and
canonicalized by T through `SemaContext::tuple_record` -- the one builder,
so a written tuple, a literal's and a substitution's are one identity with
one registry entry. No canonical is a TupleType after T; `TypeUtil::
is_tuple` / `tuple_elems` / `tuple_field` key on `StructDecl::tuple_arity`
of the pattern, by identity, never the name (`LangItems::tuple_record_name`
spells it; nothing else does). X binds `t.1` to the field `_1` (an lvalue:
`t.0 = x` assigns through) and types the element as the record's
argument. The pass then makes the tree say so: a literal becomes the
record's NamedInitializerExpr (fields in element order; EmitIR renders it
as any aggregate's), an index step becomes a Name step bound to its field
(in place: the node keeps its identity for move_sites), and `var (a, _,
c) = e` becomes one hidden local for the value -- `const T&` to an lvalue,
by value to a prvalue -- and one local per binder off its fields, moved
out of the by-value local. A match's tuple-literal scrutinee is left to
MatchLowering, which binds each element as its own column (PatternSpace
sees one Record domain; a tuple's witness still renders `(false, _)`).
`for (k, v) in xs` is IterLowering's, by the same shape. Struct
destructuring (`var {r, g} = c`) is FeatureGateCheck's SC116E. Codegen:
EmitPlan marks a tuple record OWN in every plan and InterfaceEmitter
defines it under `__KAIRO_TUPLE_<N>`, so only the arities a TU names are
emitted and two headers in one C++ TU agree.

Mono model: "Kairo enumerates and checks; C++ instantiates explicitly".
M1 walks `InstantiationRegistry::collect`; it creates nothing (T and X
did). M2 is the sync point: fills `Instantiated` nodes from their pattern,
selects partials, runs dependent conformance and resolves `T::Item`.

**The `: type` regime** [DONE, MONO.md D1]. No Kairo pass re-checks a
`: type` body per instance; there is no `retype_instance`. The body is
typed as written (a member step through the parameter is Dependent and
unbound, its call unknown), emitted as an unconstrained template, and
clang checks each instance: EmitIR spells a member chain rooted at the
parameter, and its call, as written (`x.f(args)`, `p->f(args)`, `T::f(args)`,
`.template f<A>` with generic arguments). An unbound step NOT rooted at a
`: type` parameter still ICEs: a bounded body is Kairo's to check (D0). The regime is transitional and opt-in: without
-fduck-generics, FlagGates rejects every `: type` in a program file
(SC001E, labelled at the bound; the fix-it deletes `: type` only when no
member step went through the parameter, else a note points at the first
one). Library files are exempt like every other gate, and use none.
Inside such a body a panicking call is SC116E like in any generic body,
and `match` / `==` / `===` / f-strings on the opaque `T` behave as they do
on any dependent operand. Removal: flip the default, delete the regime
branch (ChainBinding `b.duck`), the gate and the flag, after the mixin
migration (MONO.md G13/G14).

---

## 2b. Member lookup, extensions & OOP

**MERGE, not hide** [DONE]. `MemberLookup::lookup(canonical, name, out)`
walks own table -> extensions -> bases breadth-first, deduped, UNION.
The interfaces an `impl` clause names are NOT walked: an interface has no
default bodies, so each requirement is met by a member the walk already
finds, and offering the bodiless requirement beside it made every direct
call `x.f()` an SC064E tie. A bounded receiver reaches requirements
through its bounds.

**Extensions** [DONE]: indexed once per run over every parsed TU. Records
keyed by `RecordType::decl` (the primary for `extend <T> Vec<T>`); an
instance decl also consults its `instantiated_from`'s extensions. Generic
extensions on structural types keyed by shape (goes away with the
container migration); exact non-generic targets by canonical pointer.

**Instances** [DONE]: an explicit spec walks its own body. An unfilled
implicit instance walks its pattern (`instantiated_from`) -- or, when a
partial specialization's pattern matches its args, that partial
(`SemaContext::body_of`). Partial selection is done by the registry as the
instance is minted, not by M2: an exact structural match of each partial's
canonical `spec_args` against the args (`InstantiationRegistry::_select`;
no conversions, a qualifier must match exactly), then the strictly more
specialized one ([temp.class.order], simplified); two with no order
between them are SC001E at the first written mention. The choice lives on
`InstanceEntry::pattern` / `pattern_args` (the partial's own parameters'
bindings: `Store<*i32>` is P := i32 where `args` say T := *i32), and
`instantiated_from` stays the primary -- every reader of it asks "an
instance of which template", which deduction and the lang-item tests
compare. `Deduction::bind_from_record` binds both parameter spaces. A
DEPENDENT use (`Store<*P>`: an extension's receiver, a partial's own Self,
which TypeResolve spells through the primary) selects the same way at
lookup (`SemaContext::record_body`), its parameters opaque. A partial
selected by `requires` is refused (SC001E): requires-dispatch is M2's and
not built. An instance of an
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

**An interface's members are its composed requirement list** [DONE].
InterfaceComposition (T stage, after RedeclMerge, before ConstraintExtraction
and ChainBinding) normalizes every interface into `InterfaceDecl::
requirements`: its own members plus its `derives` expression's result (`+`
union, `-` difference, `&` intersection), deduplicated by identity (name,
receiver, own generic parameters with their bounds, parameter modes and
types; not the return type). MemberLookup answers an interface's names from
that list, not from its table plus a walk of its derives edges, and
ConformanceChecking builds one row over it. Conflicts, a removed associated
type a kept method names, cycles and an empty result are errors there.
private/PLAN-interface-algebra.md has the full rule set.

**Interface-conformance methods are ordinary members at lookup**
[DECIDED]. `v.push(x)` resolves the `VectorI` method bare. Two interfaces
both declaring `push` on one type collide at the use; the qualified call
form (`VectorI::push(v, x)` / `v.VectorI::push(x)`, spelling TBD) is the
tiebreak and is required before the ambiguity diagnostic can suggest it.

**Every extension member lowers to a static member of the extension scope
`__kairo_ext_X`, with an explicit receiver** [DECIDED]. Every extension
member of target X declared in namespace N (the file's module path plus
any enclosing module blocks) is a static member of `struct
N::__kairo_ext_X`, one struct per (N, X), every extend block in that scope
contributing. X is the target's leaf when the target is declared in N
itself (nested owners joined with `__`: `__kairo_ext_Outer__Inner`), and
its FULL path joined with `__` otherwise (`__kairo_ext_a__Point`): an
`impl` extend in an interface's file can target two modules' `Point`s,
and one struct per leaf would hold both or be defined twice. A generic
record is named by its primary, a builtin by its Kairo spelling
(`__kairo_ext_i32`); the name depends on the source tree alone
(invariant 9a).
The struct is always complete -- priv members included, in the preamble
and the header alike -- and all of it is public in C++: visibility is
AccessCheck's, and the struct is one text everywhere (invariant 11).
`extend Foo { fn m(self) }` is `__kairo_ext_Foo::m(Foo*)`; `a.push(19)` ->
`::std::__kairo_ext_Vec::push(&a, 19)`, qualified from `resolved_decl`
(IMPORTS.md §6.5). Receiver `Self*` /
`const Self*` from `fn f(self)` / `fn f(self) const`; a prvalue receiver
(`f().push(1)`) is materialized (`__kairo_tmp`, ExtensionLowering) and
lives to the end of the full-expression.
Extension methods are never virtual, never `override`, never a ctor.
Record extends follow the same rule; there are not two. The one exception
is an extension OPERATOR: it takes `X&` / `const X&` and its body rebinds
`self` to the reference's address. A static member cannot be an
`operator+`, so it is named by mnemonic (`LowerTargets::ext_op`:
`__kairo_op_plus`, `__kairo_op_preinc`, ...; `in`, `^^`, `await`, `spawn`,
`thread` keep their LowerTargets names), and every Kairo use is an
explicit call to it. **Operator forwarders:** beside the scope, each
extension operator C++ can spell gets an inline namespace-scope
`operator<sym>` that forwards every operand to the static member
([over.oper]/7 needs the class-typed parameter, and a C++ consumer can
then write `-x`). The postfix `int` dummy is forwarded as is.

**Friend iff the extend is in the type's file** [DECIDED]. The type's
emitted definition carries one `friend struct ::N::__kairo_ext_X;` per
same-file scope -- usually one; `module Geo { extend Point {...} }` beside
a file-scope extend is two, in two namespaces -- so their members see
`priv`; an `impl` extend in the
interface's file gets its own scope in that file's namespace and is not
a friend, so it is pub-only. The friend line is therefore closed at the
file, so a class definition is byte-identical in every TU (IMPORTS.md
invariant 12), library builds cache, and adding an extend downstream
rebuilds nothing upstream. EmitPlan: a class at Complete touches its
same-file scope, forward-declared in tier 0, since a qualified friend
needs a prior declaration.

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
the extension's), so a bound call goes through the interface's witness
class template, `VectorI_witness<T, ...>::push(&x, 1)`. The C++ shape,
where each piece is emitted, the call-site spelling and the concept are
CODEGEN.md §7b, which supersedes this paragraph's earlier text (every
conformance a specialization; the witness in the home TU only). What stays
here is what Sema must produce for it.

Keyed on `(Self, interface args)`, so `impl VectorI<i32>` and
`impl VectorI<string>` on one type coexist -- and therefore an interface
bound MUST name every interface argument (`T impl VectorI<U>`); an
unparameterized bound on a generic interface is an error, never inferred.
Non-generic code never touches a witness. The typer already binds a bound
call to the REQUIREMENT decl (`semantic_dc` owner an `InterfaceDecl`), and
that is the key; binding does not change.

**The conformance table** [PARTIAL: structural rows at a call's instance,
built by ConformanceChecking and kept in the InstantiationRegistry
(`ConformanceRow`, `row_find` / `row_add`, `InstanceEntry::rows`); declared
rows, the impl-only rule, visibility, `Box<Metric>` named by T, and M2's
dependent conformance are not built. `Sema/Mono/WitnessTable.k` is the
earlier design memo]. One per build, beside the InstantiationRegistry and for the
same reason: a row found while checking TU A is needed by every TU that
holds the same instance, so it is shared, mutex-guarded, own arena. A ROW
is

    conformer   the RecordType::decl pattern (a generic record's primary)
                or the builtin's canonical (`i32`), with the extension's
                generic params when the conformance is generic
                (`extend <T> Pair<T> impl Container<T>`: conformer
                `Pair<T>`, interface `Container<T>`)
    interface   the canonical interface instance, one row per interface
                in the derives closure (`impl Stream` is three rows)
    origin      DECLARED (`class X impl I`, `extend X impl I`: the decl)
                or STRUCTURAL (found at a use)
    witnesses   each of the interface's OWN requirements -> the decl that
                implements it: an own or inherited member, an extension
                member, or an imported C++ member. A CONSTRUCTOR
                requirement (named after its interface,
                `decl_is_ctor_requirement`) is met by an own constructor
                of the conformer -- its own table under DeclName::ctor(),
                never a base's -- matched on the non-self parameters, or,
                for a zero-parameter one on a record declaring none, by
                the implicit `X()` (the record decl stands as the
                witness). A builtin meets none: `i32()` is SC037E. A
                LIFECYCLE one (`@copy` / `@move`) is met by category
                (ClassLifecycle): `@copy` by COPY, `@move` by COPY or
                MOVE, builtins included.
                `T(args)` on a parameter whose bound promises a
                constructor of that arity types as T; any other `T(args)`
                stays unknown, as before
    sources     per requirement, the interface instance it came through at
                the row's arguments (`F<T> derives Container<T>` met as
                `F<i32>`: `Container<i32>`), so codegen spells an inherited
                requirement without substituting types itself

keyed `(conformer, interface)`. Two rows for one key are an error at the
second one's use (open: overlapping generic conformances, CODEGEN.md §7b.12
question 4). Codegen reads the decls and decides from spellings whether a
row needs a specialization; Sema records no codegen fact.

Who fills it:
- **ConformanceChecking** (C stage, after ExprTyper; item i) builds every
  DECLARED row at its declaration (interfaces.md: checked "at declaration
  time"), matching signatures as it goes, and enforces the impl-only
  rule. It also owns `conforms(X, I)`: the declared row, else a
  STRUCTURAL row built by the same match and memoized in the table.
- **At the instantiation site.** Wherever a generic's bound meets a
  concrete argument -- CallTyping registering a call's instance, a
  `Box<Metric>` named by T, and M2 substituting into a body's dependent
  instances -- the bound is checked with `conforms` and the row recorded
  on the instance: `InstanceEntry::rows`, one per `P impl I` bound, in
  bound order. A missing row is the user's error there (SC001E
  placeholder until a code is minted). The direct cases are reachable
  before M2 exists; the transitive ones (`f<T>` calling `g<T>`) are M2's
  "dependent conformance".
- **Visibility.** A row is usable in a TU iff its implementing decls are in
  that TU's transitive import set (the extension-visibility rule).

EmitPlan reads `InstanceEntry::rows` for the specialization edge; EmitIR
reads the witness ExtensionLowering records on the call (CODEGEN.md
§7b.5).

**The `: type` rule** [DECIDED]. Duck typing is C++ duck typing: a `: type`
body sees own members only. Extension members are unreachable under
`: type`: the call is emitted as a member call, and clang, finding no such
member, rejects the instance. Nothing Kairo-side reports it (no per-instance
re-check, MONO.md D0/D1).
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
3. **One error, one home.** Import existence/ambiguity: I (an ambiguity
   between header entities only: N / T at the use, IMPORTS.md §5.1). Import access:
   N(b). Redefinition / conflicting kinds: N(a). Function redefinition /
   signature disagreement / default on an out-of-line definition: R.
   Unresolved head, `Self` outside a type body
   (expression): N(b). Unknown type / arity / alias cycle / primitive
   misuse / no primary for a spec / spec redefinition / spec after
   instantiation: T. No member / wrong separator / member ambiguity /
   member of an unconstrained param: ChainBinding. Literal fit, operand
   unification, no viable overload, ambiguous call, bad cast, branch
   join, return-vs-signature, uninferrable decl: X. Unusable clang
   builtin: N(b) (R057E). Non-constant builtin argument, builtin used as
   a value: X (SC108E, SC109E). Dependent conformance:
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
   `default_thunk` / `pack_type` on ParamDecl: CallLowering.
   `init_fold` / `init_neg` / `init_mag` / `init_thunk` on FieldDecl:
   FieldInitLowering. `ci_split` / `ci_index` / `ci_slots` / `ci_dense` on
   FunctionDecl: CtorInitCheck; `ci_cut`: CtorInitLowering.
   `is_generator` / `has_yield` on FunctionDecl: X. A transfer
   constructor's `other` mode stamp: ClassLifecycle. A record's derived
   `op =` (`assign_from`, `assign_form`): ClassLifecycle. Lifecycle facts:
   ClassLifecycle, one instance owned by Sema and published as
   `sc->lifecycle`; every reader goes through `lifecycle_of(sc)`.
8. **Canonical identity is build-wide, and cv-qualified: const i32 and i32
   are two canonicals.**
9. **T never rewrites nodes.** X never allocates nodes.
10. **Builtins are not names.** (Primitive types. Clang builtins are
    foreign FUNCTIONS and are names: §2.5, the fourth source.)
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
    `<T impl I>` bounded, `<T: type>` duck (only under -fduck-generics).
    No inference of regime from use.
18. **A class definition is closed at its file.** Its friends are its
    same-file extension scopes; nothing in another file changes the
    emitted definition.
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
    g. closure bodies push a null DC                          small

Type domain (each unblocks the next):

    h. ExtensionOrphanCheck + import-scoped extension index   small
    i. ConformanceChecking: the conformance table (PARTIAL: structural
       rows at call instances, SC001E on a miss), impl-only
       members, arity/Self checks, visibility at instantiation;
       instantiating a class with a `= virtual` method is an error
    j. PatternChecking: ctor-pattern heads, bare `case n`,       DONE
       `.Variant`, exhaustiveness
    k. ADL / free operator functions (X, OperatorTyping)     DONE
    l. AccessCheck (+ `prot` same-library provenance)
    m. ConstChecking; PanicEffectChecking                  PARTIAL
    n. ExtensionLowering: `a.m()` -> `m(&a)`, prvalue receiver   DONE
       materialization (`__kairo_tmp`), generic extensions (receiver
       deduction, one merged template head). Residue: the `semantic_dc`
       rewrite
    n2. CopyMoveLowering: copying a MOVE class is an error

Mono / codegen:

    o. M1 enumeration over the registry (types AND functions)
    p. M2: fill + dependent conformance + (partial selection: done at
       registry mint, §2b Instances; requires-selected partials open).
       No `: type` re-check: clang checks those bodies (MONO.md D1)
    q. EmitWitness + EmitPlan witness edge + EmitIR witness calls   PARTIAL
       (CODEGEN.md §7b; calls, statics, operators, `I::m(x)`, generic
       requirements, records' concepts and reached instances done;
       declared rows without an instance, partial specializations open)
    r. EmitIR: `typename` / `.template` on Dependent segments/steps
       (a dependent MEMBER step is spelled as written, `.template` when it
       has generic arguments: done, D1);
       generic emission; the fwd-decl emitter (IMPORTS.md items 12, 14)