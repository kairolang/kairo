# Type resolution

This document covers the T stage of Sema: TypeResolution, RedeclMerge, EvalIfLateFolding and ChainBinding, with ConstraintExtraction, which feeds ChainBinding. InterfaceComposition also runs in this stage and is described in [Interfaces.md](Interfaces.md#interface-algebra). The order is in [the pass order](Pipeline.md#sema-pass-order). Everything before ChainBinding is `Sema::resolve_types_pre`, split out so that an import cycle can resolve every member's types before any member binds chains ([Compilation phases](Pipeline.md#compilation-phases)).

## Type resolution

`Compiler/Sema/Resolve/TypeResolve.k`. Every type node gets `canonical`, `type_flags` and its per-segment `resolved_*` slots, or is poisoned.

### Rules

- T never rewrites a node; it fills slots ([invariant 9](Pipeline.md#invariants)).
- Post-order and demand-driven. `dispatch_type` resolves children first. Aliases expand on demand (`_expand_alias`), memoized on `ResolutionState`; `type A = B; type B = A` is one error with every link as a note.
- T never dispatches a node it does not own. Foreign slots are read (`_foreign`); DAG order guarantees they are filled ([invariant 13](Pipeline.md#invariants)).
- Unqualified lookup uses the overlay of the TU the walk started in ([invariant 2](Pipeline.md#invariants)).
- Alias chain depth has its own budget, `--cmax-type-alias-depth` (default 64). The resolution stack's cap stays as the backstop and names `--cmax-scope-depth`. Both are R036E.
- An alias may not be more visible than what it names: R050E, at the alias declaration, walking the syntactic target.

### Declaration scope

A declaration's types resolve in the declaration's own lexical scope, never in the scope of whoever demanded them. Demand order may change when a type is resolved, never what it resolves to. Every out-of-walk entry (`_expand_alias`, `_demand_default`, `_register_type_spec`) goes through `_enter_decl_scope(d)` / `_leave_decl_scope`, which clears the demand site's generic frames and selfs and rebuilds `d`'s: walking `semantic_dc` outward to the first module or TU, every type scope contributes its generic frame and its `Self` (an extension: its own parameters and its target), a function its generic frame, and Block and Lambda scopes are skipped; then `d`'s own parameters. So `class <T> Box { type Elem = T }` sees Box's `T` however `Elem` is first reached.

Two exceptions, both because a local declaration can only be demanded from inside its own function: `ltypes` is kept for a local declaration (local types live on no table, only on that stack), and a statement-scope alias, which the parser leaves with no `semantic_dc`, keeps the whole walk state, since it is resolved at its DeclStmt before any use can name it. The remaining dispatches are use-site by nature (a chain's generic arguments, a pack's parameter) or walk-only (an extension's target).

### What T decides

| Node | Resolution |
|---|---|
| builtin types | by token kind, before any lookup; `i32::x` is an error |
| `self` / `Self` in type position | the innermost type scope's self (below); `Self::Inner` is a head; `Self<T>` is an error |
| heads | generic frames, then `ltypes`, then `unqualified(cur_dc)`; inside an out-of-line body whose owner is in another TU the last step is `unqualified_out_of_line` ([out-of-line bodies](NameResolution.md#name-resolution)). `_primary_of_spec` applies the same rule to a specialization whose semantic scope is an imported primary's. |
| `::` segments | step through `context_of(decl)`, alias expanded first, spelled for cross-TU probes |
| generic parameter | `generic_param(owner, index)` on the representative |
| alias | expanded; a generic alias application checks arity, takes arguments as a nominal does, and substitutes them into the aliased body (`_apply_alias`): `Mat<i32>` of `type <T> Mat = [[T]]` is `[[i32]]`. Only a body substitution cannot rewrite stays instantiation-dependent with no canonical. |
| nominal | arity, then arguments by position and name, then defaults in the primary's scope; a default naming earlier parameters gets their arguments substituted (`<K, V = K>`: `Pair<i32>` is `Pair<i32, i32>`); then specialization lookup |
| qualifiers | a written `const` / `volatile` wraps the canonical (`qualified()`); reference kinds put it on the referee |
| specializations | registered through `_register_specs_in`, which descends type and module scopes only |
| structural kinds | asked of the canonical store; dependence always flows up (`_component_ok`) |
| receiver | `ParamDecl::create_self` leaves `type_` null; T writes a `SelfType` with the enclosing record as canonical, wrapped in `const` for `const self` |
| enum underlying type | must be a builtin integer; one that cannot hold the variants is R067E |
| `extend` target | resolved first; a record target becomes `Self` |

### Dependent chains

`Foo<T>::Inner`, and `T::Item` on a `derives`-bounded `T`, are marked dependent and stop there ([invariant 5](Pipeline.md#invariants)). `T::Item` on an interface-bounded `T` resolves through the bound, definition-side, never per instance ([Interfaces.md](Interfaces.md#associated-types)). `Foo<Args>::Inner` with concrete arguments is not dependent: it steps into the registry instance (`_kairo_instance_of`). For an imported `Foo`, `_scope_of` has clang fill the instance first (`MemberLookup::ensure_filled`); only a failed fill defers.

### Self

`_selfs` holds a `*Type`, not a `*Decl`. A record body's self is `record(canon, its own params)`; an extension's is its target's canonical, pushed after the target resolves and popped with the extension. Inside `extend <T> Wrap<Box<T>>`, `self` is `Wrap<Box<T>>` over the extension's `T`. Every reader takes the type: receiver synthesis, `Self` in type position, and `_lookup_in_selfs` (which uses the record's declaration; a non-record self has no scope and is skipped). `Self` inside `extend i32` is `i32`, and `Self::X` there is R026E. ChainBinding's `ExtensionDecl` anchor keeps the record declaration for lookup but carries the real target as its type, so `Self::make()` in a generic extension sees the same `Wrap<Box<T>>`.

### Function types

A declared panic set's elements are written types in the declaration's scope, resolved in the same walk as its parameters (a generic parameter of the function is in scope). On a `fn` type they are components (`_component_ok`): a poisoned element poisons the type. The set is part of the `fn` canonical key (`CanonicalTypeStore::func`, `canon_panics`): `fn() panic(A, B)` and `fn() panic(B, A)` are one type, `fn() panic(A)` and `fn()` two, converted by subset. A function's value type carries its declared set (`ExprTyper::fn_pointer_type`), a closure's its written one. Which types may be panicked is PanicEffectChecking's ([Panic.md](Panic.md#effect-sets)).

Raw `fn` types: `unsafe fn(A) -> R` sets `FunctionPointerType::is_raw`, and the bit is in the canonical key. The raw function pointer and the `fn` value are two types; raw widens to the value and never back (`ExprTyper::check_convertible`). A named function's value type and a non-capturing closure's are raw (`fn_pointer_type`; closures via FreeVarScan); imported C/C++ function pointers are raw (TypeImport); after an `ffi "c"` function's signature resolves, its `fn` parameters and result are made raw (`_ffi_c_raw_fns`). `var g = f` and `var g = fn (...) {...}` infer the `fn` value, not the raw type (`StmtTyping::_fn_value_decay`).

Calling conventions: `fn(A) @preserve_most -> R` sets `FunctionPointerType::call_conv`, in the canonical key beside the raw bit. A type with a convention is always raw (a closure cannot carry one; CallConvCheck), so `fn_with_raw` never gives it a `fn` value twin and `_fn_value_decay` keeps it. A named function's value type carries its `FunctionDecl::call_conv`. Conversion and deduction take a convention only to itself (SC028E names both). Structural conformance compares it (`ConformanceChecking::_signature_matches`).

### Effect qualifiers

`yield T` canonicalizes to `Yield<T>` and `async T` to `Future<T>`, through the same `_lang_record` as the containers, so a generator's value has the members its lang class declares (`g.next()`, `g.current()`). The qualifier stays on the syntax node: `TypeUtil::is_generator_return` and the typer frame read it there (a spelled-out `Yield<T>` is an ordinary return), and an `async T` frame types its `return`s against the inner `T`.

### Containers

`[T;]`, `[T]`, `{T}`, `{K: V}` and `string` are sugar for the records `builtin::Slice<T>`, `Vector<T>`, `HashSet<T>`, `HashMap<K, V>` and `string`, declarations in the builtin root reached through `sc->well_known`. `_resolve_vector`, `_resolve_set`, `_resolve_map` and the incomplete-array arm produce `record(item, args)`; an unbound item is R053E at the use. `VectorType`, `SetType` and `MapType` remain as syntax nodes whose canonical is a `RecordType`. `extend <T> [T]` is legal syntax for `extend <T> Vector<T>`.

`*T`, tuples, `fn` pointers and `[T; N]` stay structural. `[T; N]` needs const generic arguments in the registry key before it can be a record, and it is also the FFI shape of a C array. An FFI-imported incomplete array keeps the structural `array(elem, 0)`. A `[...]` literal is a `Slice<E>` (or takes an expected `[E; N]` outright); `Slice<T>` to `Vector<T>` is the one container conversion, rank Converted.

### Pointers

`unsafe *T` and `*T` are distinct canonicals: `PointerType::is_unsafe` is in the canonical store's key (`CanonicalTypeStore::pointer`), which makes the `as unsafe *` cast family decidable.

### Array lengths and value arguments

An array length is folded here (`_resolve_array`) by ConstEval, untyped: literals, `eval` variables, `eval` fields, and arithmetic over them ([Eval.md](Eval.md#evaluation-model)). A length read from an `eval` field of the field's own class whose initializer does not fold is SC116E with a fix-it hoisting the constant to module scope (`_own_class_constant`; `_cur_field` is the field being resolved): C++ would compute it, and inside its own body the class is incomplete. A literal `N` gives a canonical `[T; N]`.

What does not fold is kept for C++. A length or generic value argument over value parameters (`N + 1`), an `eval` constant whose initializer does not fold, an `eval` call (`f(3)`), an enclosing unrolled `eval for`'s binding, `+ - * / % << >> & | ^`, unary `-` / `~`, and `as` to an integer type become an interned canonical value node (`TypeExpr`, `ValueOp`; `_value_expr`, `CanonicalTypeStore::value_expr`): `[T; N + 1]` is `array_of_param(T, (N + 1))`, and `Buf<f(3)>` has that node as its argument. Node identity, folding after substitution (`ConstEval::value_node`, called by ArgumentDeduction) and the `eval` class cases are specified in [Eval.md](Eval.md#evaluation-model). Such a node is accepted in any position, a declaration's type included; EmitPlan defines the `eval` functions, constructors and bindings it names ahead of the declaration ([Codegen.md](Codegen.md#emitplan)). Where no order exists, EvalUsageChecking reports it.

## Redeclaration merging

`Compiler/Sema/Resolve/RedeclMerge.k` (R) links function redeclarations. It has three parts: R(a) walks the frozen cells and pairs declarations by signature; R(b) matches each out-of-line `fn Class::method` against the in-class set; R(c) checks `inline` definitions.

### The signature

Two function declarations are one entity when their signatures agree:

| Component | In the signature |
|---|---|
| arity, canonical parameter types in order, generic arity | yes |
| return type | no; a mismatch is a conflict, not an overload |
| `const` | excluded for Kairo-authored declarations; included for foreign ones and for `[]` (keyed on operator kind, `is_place_kind`, so place and value forms alike), the one exception to the const-overload restriction |
| fixity | yes: `op l++` beside `op r++` is two functions |
| top-level parameter cv | no, as C++ [dcl.fct]/5: the binding's `const` and a `const` at the top of the type. `f(x: const *i32)` and `f(x: *i32)` are one function; `f(*const i32)` and `f(*i32)` are two. The receiver's `const` is one level down and stays. |
| `@copy` / `@move` marker | yes when both carry one, since `other` is written bare and ClassLifecycle stamps its mode only in the checks: `@copy fn X(self, const other: Self) = delete` beside `@move fn X(self, other: Self) = delete` is `X(const X&)` and `X(X&&)` |
| bounds | no (below) |

R(a) never merges two constructors that both carry a marker: how many transfer constructors a class may have is ClassLifecycle's rule (SC057E), which would otherwise lose a second `@copy` differing only in `const` on `other` to R041E. R(b) includes the marker kind, so an out-of-line definition that repeats it still finds its declaration.

Across a chain, return type, defaults, linkage and modifiers must agree. File scope permits repeated declarations; a type body does not ([class.mem]); a repeat is R041E. Receiver const-ness is part of the signature for an imported declaration and for the two place operators, `op []` and `op ->` (`OperatorFacts::is_subscript`, `is_arrow`): a `self` / `const self` pair of either is two entities, chosen by the receiver's const. For any other Kairo declaration the pair is one entity with two contracts. `op []=` has no const pair.

A pair with distinct signatures whose parameters all lower to the same C++ types is R052E at the second declaration (`f(u64)` / `f(usize)` on a 64-bit target, where `usize` is `size_t`), because the emitted C++ would declare one function twice. Only the builtin table is compared (`usize` / `isize` against the fixed-width integer of `target.pointer_width`); records, pointers and references compare by canonical as identity does. Kairo-authored pairs only.

### Generic signatures

Generic signatures compare up to the names of their parameters. Each declaration's `T` is a `GenericParamType` owned by that declaration, so `_same_signature` first reads the second declaration's parameter types over the first's (`Substitution::bind_redecl`: `bind_alpha` plus value parameters whose declared types are one canonical, keyed on each declaration rather than its representative, since T built the canonicals before R linked anything) and then compares. `fn <T impl G> g(x: T)` followed by `fn <U impl G> g(x: U) { ... }` is one function, out of line too (`fn <W> C::m`). Return agreement substitutes the same way.

Bounds are not in the signature. A file-scope declaration and definition that disagree about a parameter's bounds (the requires clause's `impl` / `derives` conjuncts) is R061E at the later one. Only a pair with at most one body links (`_one_entity`): two generic definitions of one shape stay two overloads whatever their bounds (a `where` group's members, or a constraint-ordered pair), and so do two bodiless members differing only in their bounds. Packs never align. Codegen spells every link's template head from the representative (`CXXSpell::template_head`).

### `op as`

`op as` is the one operator whose return type is part of its identity: two `op as` with different result canonicals are two entities (`operator int` / `operator long` in C++, so R052E is skipped for them); two with one result are R041E, named `'op as'`. CastTyping selects by exact result; a generic record's `op as -> T` is compared through the source instance (`Wrap<i64> as i64`), and OperatorLowering hands EmitIR the bound target so the call spells `operator long` rather than the template's `operator T`. InterfaceComposition treats two `op as` requirements with different results as two requirements, and their witness members carry the target in the name (`LowerTargets::witness_conversion`).

### Defaults and `inline`

An out-of-line definition may not carry a default: R056E, in R(b). A method's defaults are its in-class declaration's; the default is cleared once diagnosed and the definition still links. Free-function redeclarations accumulate defaults.

`inline` is part of modifier agreement for Kairo-authored links (R039E), though C++ lets a later declaration add it: it decides where the body is emitted, and an importer reads it off the in-class declaration while the home TU reads the definition. After R(a) and R(b), R(c) reports every Kairo `inline` function whose chain has no definition, R062E: it would be declared inline in C++ with a definition nowhere. The check is per TU, so the body must be in the declaring file, which an importer needs anyway. `= default` and `= delete` count as bodies. A pure virtual method is a `virtual fn` with no body; the old `= virtual` spelling is S047E with a fix-it removing it (`DeclParse`).

### Deferred `eval if` and `where` groups

Two functions in sibling branches of one deferred `eval if` are never paired by R(a), as one entity or as overloads: EvalIfLateFolding keeps one of them.

Two same-signature functions either of which has a `where` guard are never linked: they are members of one dispatch group, not one entity. After the pairwise loop, R(a) stamps `FunctionDecl::where_lead` (the first member in the cell, which is source order) on every safe, unpoisoned function sharing a guarded one's signature. An `unsafe` function is never a member. Two unguarded same-signature definitions still link, so a second fallback is R029E. OverloadResolution maps every candidate to its `where_lead` before it deduplicates, so a group is one candidate with one signature and every call, in every TU, binds to the lead. Generic groups are formed equal up to parameter names and judged by WhereGuardCheck ([Check passes](SemanticChecks.md#check-passes)).

## Late eval-if folding

`EvalIfFolding::run_late()` (`Compiler/Sema/Expand/EvalIfFolding.k`) is its own pass in the T stage, after RedeclMerge and before InterfaceComposition, ConstraintExtraction and ChainBinding. It decides every declaration-scope `eval if` that [expansion](NameResolution.md#expansion) deferred on a type fact, with E's own writer (the same hoisting, `_members_from_branches` and frozen-table rebuild), so every pass after it sees one branch: X, the lowerings and codegen are untouched, and ConstraintExtraction, TypeCycleCheck and ShadowCheck never see a discarded branch. It replaces tables exactly as E does ([invariant 1](Pipeline.md#invariants)) and is not part of T ([invariant 9](Pipeline.md#invariants)).

The facts:

| Fact | Source |
|---|---|
| `sizeof`, `alignof` | `EnumLayoutQuery::size_of`: builtins, pointers, arrays, plain enums and plain records of them. Any other layout is C++'s to choose: SC230E, with a note pointing at `if constexpr`. |
| `is_trivially_copyable!`, `is_trivially_destructible!` | `ClassLifecycle::facts_of_type_concrete` |

A fact about a type parameter is SC132E: a generic is one C++ template and C++ has no class-scope `if constexpr`, so its members cannot differ per instance; the note spells the requires-selected partial specialization to write instead ([Generics.md](Generics.md#instantiation-model)).

A fact about a record whose own member set another deferred `eval if` still decides (the record itself, or one it holds by value through a field, base, array element or type argument), and a name only such branches declare, wait: the walk repeats while a round folds something, calling `ClassLifecycle::forget_facts()` after each such round, and when a round folds nothing one last round reports what still waits (SC230E). Then `LateFoldRebind` rebinds every `NamedIdentExpr` N bound to a discarded declaration (`resolved_decl`, or a `candidate_cell` holding one) to the survivor of that name in that scope; no survivor is R020E. A TU that already has an error is not folded: the stage stops at its end.

The agreement pin: an `eval` constant of this TU whose value the fold read through a type fact records that value (`fold_pin`), and codegen writes `static_assert(NAME == value, ...)` right after the constant's C++ definition (EmitIR `_global_var` / `_eval_field_def`, InterfaceEmitter `_static_def`). Clang computing another value fails the build. `--test-fold-lie` (tests only) inverts the fold's triviality facts to show it.

Not implemented: a type that reads a constant a deferred branch declares (`[u8; W]`) is resolved by T before the fold decides which `W` exists; a type declared in a deferred branch is refused in E.

## Chain binding

`Compiler/Sema/Resolve/ChainBinding.k`, the last pass of the T stage. It walks every `ChainExpr` left to right from an anchor and binds each step.

### Constraint extraction

ConstraintExtraction (`Compiler/Sema/Check/ConstraintExtraction.k`) runs just before ChainBinding. It partitions each declaration's canonical `requires_clause` (already the single source of bounds, by [RequiresDesugar](NameResolution.md#expansion)) into conformance constraints and value predicates and files the result in `sc->bounds`, keyed by owner declaration. ChainBinding's dependent path and ConformanceChecking read it: what `x.draw()` on an `x: T` may bind to is exactly what `T`'s declaration promised.

### Steps

| Anchor kind | Step |
|---|---|
| Module | `::` does table lookup over every reopened scope, unioned, with re-exports through the module's overlay; `.` is an error |
| Type | `::` does member lookup; `.` is an error |
| Value | `.`, `->`, `?.`, `?->` peel the wrapper, then member lookup on the canonical; `::` is an error. `->` on a record goes through its `op ->`, chained while the result is a record (`Substitution::arrow_target`). |
| NeedsInference, Errored | record why and stop |
| Dependent | the three regimes, below |

Anchors:

| Head | Anchor |
|---|---|
| parameter, field, typed variable | Value |
| class, struct, enum, interface, alias | Type |
| `Self` bound to an `ExtensionDecl` | Type (its target) |
| module; an `ffi` alias (it denotes the header TUs' ModuleDecls) | Module |
| generic parameter | Dependent, carrying its canonical; a value parameter of an `eval` class (`<eval C: Config>`) is a Value of that class |
| call, inferred variable, overload set, operator or tuple-index step | NeedsInference |
| `.` / `->` on a value whose declared type is nullable | NeedsInference: whether it reads the value depends on the nullness analysis at that use, which only the typer has ([Nullables.md](Nullables.md#passes)) |

A module anchor's scopes are its whole reopening ring (`NameLookup::module_scopes`, deduplicated), from a single declaration as much as from an all-module cell: N collapses a same-TU reopened module to its canonical, and `Util::b` must still find a `b` in the second `module Util { }` block.

A type head with explicit arguments (`Box<i32>::make()`) anchors as the registry instance: positional, complete, no packs, no names. A dependent record is still looked up by name (`self.x` in `class <T> Foo` binds to the field). Cross-TU probes are spelled, never keyed by interned id.

Commit rule: one declaration goes to `resolved_decl`; an all-function result to `candidate_cell`; distinct non-function entities under one name are an ambiguity error (R028E). Each step's outcome is recorded in `ResolutionTrace`. Other errors here: no member (R025E), wrong separator, member of an unconstrained parameter (R051E).

### Two callers, one binder

`bind_step(chain, st, anchor)` is public. ChainBinding calls it from its own walk with anchors it computes from declared types; the expression typer (MemberTyping) calls it for every NeedsInference step once it knows the base's type, with `anchor_for_value(decl, canonical)` / `anchor_for_type(t)`. When MemberTyping is the caller, a nullable anchor is bound on the narrowed `T` or fails with "no member in 'T?'".

### C++ templates over Kairo parameters

A `::` step on an imported record instance whose arguments are dependent (`cxx::std::is_trivially_destructible<T>::value`) is a C++ dependent qualified name: C++ looks it up per instantiation, and its members may come from a base over a builtin of the arguments or from a partial specialization the pattern does not show. A name the pattern declares still binds; one it lacks is left unbound and the expression instantiation-dependent (MemberTyping). EvalUsageChecking reads it as a compile-time value in an `eval if`, and EmitIR spells it through the instance (`::std::X<T>::value`) for clang to resolve. The concrete form (`<i32>`) binds through the instance.

### The three regimes

A step on a value whose canonical is a bare `generic_param(owner, i)` reads `owner`'s `GenericParamDecl[i]` and its bounds (from `sc->bounds`). The regime is the declaration's ([invariant 17](Pipeline.md#invariants)):

| Declaration | Regime |
|---|---|
| `<T>` | opaque: no members, no `::`; a step on it is R051E at the definition ("'T' has no members") |
| `<T impl I>` | bounded: member lookup over `I` and what `I` derives, unioned across bounds, binding to `I`'s requirement declaration. A `derives B` bound exposes `B`'s members likewise. Checking is definition-side: the error lands on the template, not on an instantiation. |

A dependent composite (`*T`, `[T]`, an unfilled `Foo<T>::Inner`) is Dependent under every regime: it has no scope to look into.

### `eval if T impl I` narrowing

A function-body `eval if` stays `if constexpr`; its `T impl I` conjunct is `I`'s concept (`EmitIR::_constraint`), so C++ decides it per instantiation and discards the other branch. In the taken branch, `I` is a bound of `T` for every step ChainBinding's own walk binds (`T::f(...)`, `T::Assoc`): `_bounds_of` adds it while the branch is walked, so the step binds to `I`'s requirement and is spelled through `I`'s witness. Only `&&` conjuncts narrow, only `impl` over a generic parameter (EvalUsageChecking rejects the rest), and the else branch sees the declared bounds. Steps the expression typer binds (`x.f()` on `x: T`) and operators (`TypeUtil::checked_param`) do not see the narrowing.

### Checked parameters in the expression typer

The expression typer applies the bounded rule to operators, conversions, f-string holes and patterns on a bounds-checked parameter (`TypeUtil::checked_param`); see [ExprTyping.md](ExprTyping.md#expression-typing).
