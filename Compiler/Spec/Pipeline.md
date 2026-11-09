# Pipeline

## Overview

Semantic analysis (Sema) turns each parsed translation unit (TU) into a resolved, typed, checked and lowered tree that codegen can spell as C++. It runs once per Kairo TU of the build. Foreign TUs (C/C++ headers) have no Sema run: their declarations come from clang already resolved.

`Compiler/Sema/Sema.k` is the scheduler and holds no semantic logic. Every pass lives in its own file and borrows the TU's `SemaContext` (`Compiler/Sema/SemaContext.k`); passes communicate only through the AST (resolved links, `type_` slots, poison bits, redeclaration chains) and the shared registries, never through each other. `Sema.k` is the only file that imports passes.

A TU's progress is `SemaContext::phase`, a `SemaPhase` that only moves forward. Each stage asserts its precondition with `require_phase` and ends with `advance_phase`, so a pass cannot run against a tree in the wrong state. `Sema::run_to(target)` is re-entrant: a second call continues from the current phase and never re-runs a finished stage (`_already`).

| `SemaPhase` | Reached after |
|---|---|
| `Parsed` | parse: every scope's symbol table built and frozen, `out_of_line` definitions collected |
| `ImportsResolved` | I: the TU's import overlay is built |
| `Expanded` | E: surface rewrites |
| `Verified` | V: structural checks |
| `NamesResolved` | N: name binding |
| `TypesResolved` | T stage: types, redeclarations, late folds, chain binding |
| `Typed` | the typed checks, through ConformanceChecking |
| `Checked` | the late checks, after the panic-set barrier |
| `Lowered` | the lowerings |
| `MonoCollected` | M1 |
| `Complete` | M2 |

## Compilation phases

The driver (`FrontendAction::_sema` in `Compiler/Driver/FrontendAction.k`) runs Sema over every fid of the action's import graph after preprocessing and parsing (see [Driver phases](Driver.md#driver-phases)).

Order is the import DAG. `_import_order` lists the graph in reverse import-tree order, so a module's pipeline runs before any importer's. Three stages depend on it: I needs every source overlay complete before it folds re-exports; T reads an imported file's nodes only after that file's own T settled them; X reads an imported expression-bodied function's return type, which that function's own TU filled. The loop order is load-bearing.

The graph is cut into groups (`ImportGroups`), one per strongly connected component of the import graph, each placed after every group it imports and otherwise in import order. With no import cycle every group is one TU. An import cycle is one group. How the preprocessor detects and reports a cycle (R058W, R058E under `-fno-import-cycles`) and pre-collects its macros is in [Lexing.md](Lexing.md#preprocessor).

`FrontendAction::_sema_group` runs one group:

1. Each Kairo TU of the group gets a `Sema`, allocated in an arena so its address never moves (Sema keeps `&self.sc`, and the context keeps `&self.lifecycle`, from its constructor on).
2. Every TU goes to `Typed`. A one-TU group does this in one `run_to`. A larger group runs in lockstep: one phase (I, E, V, N, T, typed checks) across every member before the next, because each phase of one member reads what the same phase of another produced. Inside the T stage, `Sema::resolve_types_pre` runs for every member before any member's ChainBinding, since binding walks other members' records through `derives` edges their T resolves. After I, the group's re-exports are folded to a fixpoint (`ImportResolution::refold_reexports`): the member that ran I first folded its sources' re-exports from overlays not yet built. A member whose stage fails stops there; the others continue.
3. The panic-set barrier (see [Phase barriers](#phase-barriers)).
4. Each TU continues to `Checked`, then the lowerings and mono. The TU that declares the `Nullable` lang item goes first, since every other TU's `T?` lowering reads the layout that TU's EnumLayoutLowering builds. Diagnostics are drained into the driver's sink per TU.

Each group's stages up to ConformanceChecking (its front) run on the thread pool, beside other groups' fronts and the driver's late part of earlier groups; Conformance, the barrier, the late checks, the lowerings and mono run on the driver one group at a time in this order. `--sema-threads=1` runs the whole loop on the driver. See [Parallel Sema](Performance.md#parallel-sema) and [invariant 4](#invariants).

### Dumps

Each dump is pinned to a phase, so it shows one pass's output whatever runs later.

| Flag | Dumps at |
|---|---|
| `--print-ast` | end of parse, before Sema |
| `--print-sema` | after `run_to(Checked)`: X's output, before any lowering rewrites the nodes it names |
| `--print-lowered` | after the lowerings; a test that asserts what a lowering produced uses this one |

Splitting the run at `Checked` does not lose the hard stop: a TU that stopped before `Typed` is not continued, and the lowerings run only when `run_to(Checked)` succeeded.

## Sema pass order

The schedule, as `Sema.k` runs it. This table is the one statement of the order; other documents describe passes and link here.

| Stage | Pass | File | Described in |
|---|---|---|---|
| P | parse | `Compiler/Parser/` | [Parsing.md](Parsing.md#parser-structure) |
| I | ImportResolution | `Compiler/Sema/Resolve/ImportResolution.k` | [Imports.md](Imports.md#import-resolution) |
| E | `@no_warn` scopes (`AttributeCheck::register_suppressions`) | `Compiler/Sema/Check/AttributeCheck.k` | [NameResolution.md](NameResolution.md#expansion) |
| E | PrimitiveLimitDesugar | `Compiler/Sema/Expand/PrimitiveLimitDesugar.k` | [NameResolution.md](NameResolution.md#expansion) |
| E | AllocSugarDesugar | `Compiler/Sema/Expand/AllocSugarDesugar.k` | [NameResolution.md](NameResolution.md#expansion) |
| E | EvalIfFolding | `Compiler/Sema/Expand/EvalIfFolding.k` | [NameResolution.md](NameResolution.md#expansion), [Eval.md](Eval.md#passes) |
| E | RequiresDesugar | `Compiler/Sema/Expand/RequiresDesugar.k` | [NameResolution.md](NameResolution.md#expansion) |
| V | LoopContextCheck, ArmOrderCheck, JumpLabelCheck, PatternBindingCheck, CxxNameCheck, ModulePinCheck | `Compiler/Sema/Verify/` | [NameResolution.md](NameResolution.md#verification) |
| N | NameResolution, then `fill_lang_items` | `Compiler/Sema/Resolve/NameResolution.k` | [NameResolution.md](NameResolution.md#name-resolution) |
| T | TypeResolution | `Compiler/Sema/Resolve/TypeResolve.k` | [TypeResolution.md](TypeResolution.md#type-resolution) |
| T | RedeclMerge | `Compiler/Sema/Resolve/RedeclMerge.k` | [TypeResolution.md](TypeResolution.md#redeclaration-merging) |
| T | EvalIfLateFolding (`EvalIfFolding::run_late`) | `Compiler/Sema/Expand/EvalIfFolding.k` | [TypeResolution.md](TypeResolution.md#late-eval-if-folding) |
| T | InterfaceComposition | `Compiler/Sema/Check/InterfaceComposition.k` | [Interfaces.md](Interfaces.md#interface-algebra) |
| T | ConstraintExtraction | `Compiler/Sema/Check/ConstraintExtraction.k` | [TypeResolution.md](TypeResolution.md#chain-binding) |
| T | ChainBinding | `Compiler/Sema/Resolve/ChainBinding.k` | [TypeResolution.md](TypeResolution.md#chain-binding) |
| C | AttributeCheck | `Compiler/Sema/Check/AttributeCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | TypeCycleCheck | `Compiler/Sema/Check/TypeCycleCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | OperatorSignatureCheck | `Compiler/Sema/Check/OperatorSignatureCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ClassAllocatorCheck | `Compiler/Sema/Check/ClassAllocatorCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | PackChecking | `Compiler/Sema/Check/PackChecking.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ExprTyper (X) | `Compiler/Sema/Type/` | [ExprTyping.md](ExprTyping.md#expression-typing) |
| C | ValueCategoryPass | `Compiler/Sema/Check/ValueCategoryPass.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ShadowCheck | `Compiler/Sema/Check/ShadowCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ShorthandLint | `Compiler/Sema/Check/ShorthandLint.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | PatternChecking | `Compiler/Sema/Check/PatternChecking.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ReturnPathCheck | `Compiler/Sema/Check/ReturnPathCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | FnPurityCheck | `Compiler/Sema/Check/FnPurityCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | CallConvCheck | `Compiler/Sema/Check/CallConvCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ScopeEscapeCheck | `Compiler/Sema/Check/ScopeEscapeCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ControlFlowAnalysis | `Compiler/Sema/Check/ControlFlowAnalysis.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | JumpLabelCheck script rule (`run_script_jumps`) | `Compiler/Sema/Verify/JumpLabelCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | WhereGuardCheck | `Compiler/Sema/Check/WhereGuardCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ClassLifecycle | `Compiler/Sema/Check/ClassLifecycle.k` | [Ownership.md](Ownership.md#copy-and-move) |
| C | ClosureCaptures | `Compiler/Sema/Check/ClosureCaptures.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | MoveCheck | `Compiler/Sema/Check/MoveCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | AccessCheck | `Compiler/Sema/Resolve/AccessCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | `@deprecated` uses (`AttributeCheck::run_uses`) | `Compiler/Sema/Check/AttributeCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | InitCheck | `Compiler/Sema/Check/InitCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | BaseInitCheck | `Compiler/Sema/Check/BaseInitCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | CtorInitCheck | `Compiler/Sema/Check/CtorInitCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | ConformanceChecking (phase becomes `Typed`) | `Compiler/Sema/Check/ConformanceChecking.k` | [Interfaces.md](Interfaces.md#conformance) |
| barrier | EffectPropagation (driver, per group) | `Compiler/Sema/Check/EffectPropagation.k` | [SemanticChecks.md](SemanticChecks.md#effect-propagation) |
| C | PanicEffectChecking | `Compiler/Sema/Check/PanicEffectChecking.k` | [Panic.md](Panic.md#passes) |
| C | EvalUsageChecking | `Compiler/Sema/Check/EvalUsageChecking.k` | [Eval.md](Eval.md#passes) |
| C | FeatureGateCheck | `Compiler/Sema/Check/FeatureGateCheck.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | FlagGates | `Compiler/Sema/Check/FlagGates.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| C | PatternCompilation (phase becomes `Checked`) | `Compiler/Sema/Lower/PatternCompilation.k` | [SemanticChecks.md](SemanticChecks.md#check-passes) |
| L | the lowerings, then (under `-finfer-purity`, the default) PurityInference, ParamPassInference | `Compiler/Sema/Lower/`, `FnPurityCheck::infer` | [Lowering.md](Lowering.md#pass-order) |
| M1 | instance enumeration (`ConformanceChecking::discover`) | `Compiler/Sema/Check/ConformanceChecking.k` | [Generics.md](Generics.md#monomorphization-sync-point) |
| M2 | instance facts (`PanicInstances`, `EnumLayoutQuery::sweep`) | `Compiler/Sema/Lower/PanicLowering.k`, `Compiler/Sema/Lower/EnumLayoutLowering.k` | [Generics.md](Generics.md#monomorphization-sync-point) |

Three planned passes have stub files and are not scheduled: MacroExpansion (E), ConstChecking (C) and LayoutPass. ExtensionOrphanCheck, the home of orphan errors in [invariant 3](#error-homes), does not exist yet.

## Phase barriers

### Hard stops

`Sema::_hard_stop` is true when the stage reported errors beyond the ones it contained (`SemaContext::contained_errors`: errors that only poison their own uses). The policy per stage:

| Stage | On error |
|---|---|
| I, E, V | stop before the next stage |
| N | continue into T; N poisons every name it could not bind, and T over the rest of the TU is what gives declarations their types. T's gate counts N's errors, so nothing past T runs. |
| T stage | stop before the checks |
| typed checks, late checks | keep going; poisoned nodes carry the state. An error still keeps the TU out of the lowerings (`run_to(Checked)` returns false). |
| M1, M2 | stop |

Running checks or lowerings over a tree whose names or types never resolved produces cascade noise, so the resolution stages stop the pipeline. The lowerings carry no diagnostics: a construct they cannot render is reported by FeatureGateCheck, which keeps the schedule out of the lowerings, so a lowering ICE stays an internal error. This applies under `--type-check-only` too, which runs through the lowerings.

### The Typed barrier

The barrier between `Typed` and `Checked` is the one point where a TU waits for others. A panic set is the union of what a body raises and what its callees leave, and a callee is always in the caller's import closure (an override's or a conformer's set is bounded by the base's or requirement's declared set), so a TU's sets are final once every TU it reaches through imports is typed ([Panic.md](Panic.md#effect-sets)). Each group therefore goes to `Typed` as a whole; then the build-wide `EffectTable` is reset, registers each member that reached `Typed`, and solves every inferred set of the group to one fixpoint (see [Effect propagation](SemanticChecks.md#effect-propagation) and [the solve](Panic.md#the-solve)). Only then does any member run the late checks. In an acyclic graph this is the one-TU-at-a-time loop, and a TU's lowerings still run before the next TU is typed.

A TU that stopped before `Typed` (a hard stop in I, N or T) is neither registered nor continued; a call into it says nothing about panics. A TU that reached `Typed` with errors is registered, and its poisoned nodes are skipped.

## Invariants

The hard invariants of the pipeline. Code cites them by number.

| No. | Invariant |
|---|---|
| 1 | Frozen means frozen. A symbol table frozen at parse is never mutated by any later pass. A pass that must change one (EvalIfFolding, EvalIfLateFolding, `_bind_cxx`) builds a new frozen table and replaces it. |
| 2 | One key space per TU. Interned keys are only meaningful in their own TU; a cross-TU probe goes through the spelling shim, and unqualified lookup consults the overlay of the TU the walk started in. A raw `lookup_symbol` or imm-keyed `unqualified` on a scope that may be foreign is a silent wrong answer, not a miss. The crossing entry points are `MemberLookup::in_scope`, `NameLookup::in_context` (with a spelling) and `NameLookup::unqualified_out_of_line`. An out-of-line body of an imported member, the one walk that starts in a foreign chain from this TU's code, also falls back to the definition's lexical scope, since the owner's parents are the header's. |
| 3 | One error, one home. Each error is reported by exactly one pass; see [Error homes](#error-homes). |
| 4 | Parallelism boundary. Parsing is parallel. Sema's fronts (I through the typed checks before Conformance) run in parallel across import groups that do not import each other, each once its imports have finished all of their Sema; everything from Conformance on runs on the driver, one group at a time in DAG order (`FrontendAction::_sema_parallel`). The canonical type store and the instantiation registry are the shared mutable structures; both are locked, and T, X, ConformanceChecking, the lowerings and `EnumLayoutQuery::sweep` all write them from every TU. Determinism rests on the one-thread order, not on timing: `home_fid` (first namer) and the registry's worklist follow each request's key in that order, every first-writer fact is written on the driver in DAG order or keyed the same way, and nothing that reaches output depends on a hash ([Parallel Sema](Performance.md#parallel-sema)). |
| 5 | Dependent means deferred, not failed. A dependent type is marked, not resolved; X's unknown state is the same rule on expressions. `Tests/Sema/ExprTyper/nomono.k` is its test. |
| 6 | Tracing never changes behavior (`ResolutionTrace`). |
| 7 | One writer per fact. Each AST slot has exactly one writing pass; see [Fact writers](#fact-writers). |
| 8 | Canonical identity is build-wide and cv-qualified: `const i32` and `i32` are two canonicals. |
| 9 | T never rewrites nodes; it fills slots. X never allocates nodes. |
| 10 | Builtin (primitive) types are not names: they are decided by token kind and live in no table. Clang builtins are foreign functions and are names ([Lookup rules](NameResolution.md#lookup-rules)). |
| 11 | Imports are erased at N and ChainBinding. No pass after them reads an `ImportDecl`. A codegen decision that needs to know how something was imported is a bug; it asks the declaration where it lives (`is_imported()` for a C++ header's). |
| 12 | `RecordType::decl` is the record whose body defines the instance. |
| 13 | T never dispatches a foreign node; it reads the slots, which DAG order has filled. X reads a foreign declaration's slots (return type, inferred variable type) and never types a foreign body. |
| 14 | The representative of a redeclaration chain is the only identity. |
| 15 | The written cast target is the result type: `a as T` has type `T`, always. |
| 16 | Two conversion ranks, unordered within rank 2. The only tiebreak is non-generic over generic among Exact winners, which is not a conversion ordering; `-fno-implicit-conv` can therefore remove a candidate but never select a different one ([Conversions](ExprTyping.md#conversions)). |
| 17 | A generic parameter's regime is its declaration's: `<T>` opaque, `<T impl I>` bounded. No regime is inferred from use ([Chain binding](TypeResolution.md#chain-binding)). |
| 18 | A class definition is closed at its file. Its friends are its same-file extension scopes; nothing in another file changes the emitted definition. |
| 19 | An interface bound names every interface argument. |
| 20 | One namespace per declaration, derived and never stored per use. A declaration's C++ namespace is its DC parent chain mapped through `ModuleDecl::module_path`; every TU that emits the declaration computes the same path from the same node. |
| 21 | Nothing outside the source tree reaches the ABI. A declaration's C++ namespace is a function of its root's declared name, its path within that root, and any enclosing `module X { }` blocks: not the checkout directory, a flag, or the importer's spelling. Two builds of one tree emit byte-identical interfaces. A pathless TU (outside every search directory and library) declares no root, so its namespace is its file stem; `main` is always the global one. A path segment is spelled as a C++ identifier the way the stem is (`CXXSpell::cxx_segment`: `operator.k` is `operator_`). |
| 22 | Compiler-invented names come from one file. `Compiler/AST/LangItems.k` holds lang items (declarations a user could have written, arriving through ordinary imports and filled once per build on the `GlobalDisambigTable`) and lower targets (fragments of C++ names no Kairo declaration spells, such as `__kairo_contains` for `op in` and `__kairo_pow` for `op ^^`). Nothing else carries a copy of those strings; a pass that needs one asks that file. `CxxNameCheck` rejects a user identifier with the reserved prefix, so an invented name never collides with a written one. |
| 23 | Aliases are TU-local. An alias never appears in an exported interface; C++ consumers see canonical names only. |
| 24 | Class granularity. A class enters a TU's emitted interface whole (every member declared) or not at all. |
| 25 | Bodies are out of line. A class body contains no function bodies, in its home TU too, which keeps the class definition byte-identical across TUs (C++ ODR). A body is emitted in its home TU only, except the bodies that are part of the interface: templates and `inline` functions, which every TU and header that sees the declaration also emits out of line as C++ `inline`, with the same text (clang instantiates templates Kairo never lists, and `inline` is the author asking importers to compile the body). Members the compiler synthesizes (ADT special members rendered from `adt_role`/`adt_form`, derived assignment operators) carry their bodies inside the class; no user-written body is ever emitted in-class. See [Codegen.md](Codegen.md#templates). |
| 26 | Kairo enumerates every instance it can see. Every generic instantiation visible to Kairo is enumerated by Sema (M1, the registry's worklist), checked once against its bounds, and emitted explicitly in its home TU. Clang instantiates only what Kairo never names (a coroutine's promise, `std::sort` calling a Kairo comparator, a C++ host) from the visible bodies. Emitted templates carry no `requires` except the interface concepts EmitWitness derives (one conjunct per interface bound, true for every instance Kairo enumerated) and a record's self-contained value predicates; for instances only C++ sees, those are the real check. ADT special members and a generic record's derived assignment operators carry C++ constraints rendered from `adt_role`/`adt_form`/`assign_form`; those are not Kairo constraints and have no `requires_clause`. See [Generics.md](Generics.md#instantiation-model). |

### Error homes

Invariant 3 in full. "N(a)" and "N(b)" are the two halves of [name resolution](NameResolution.md#name-resolution); "R" is [RedeclMerge](TypeResolution.md#redeclaration-merging).

| Error | Home |
|---|---|
| import existence, import ambiguity | I; an ambiguity between header entities only is reported at the use, by N or T ([Imports.md](Imports.md#import-resolution)) |
| import access | N(b) |
| redefinition, conflicting kinds | N(a) |
| function redefinition, signature disagreement, default on an out-of-line definition | R |
| unresolved head; `Self` outside a type body in expression position | N(b) |
| unusable clang builtin (R057E) | N(b) |
| unknown type, arity, alias cycle, primitive misuse, no primary for a specialization, specialization redefinition, specialization after instantiation | T |
| no member, wrong separator, member ambiguity, member of an unconstrained parameter | ChainBinding |
| literal fit, operand unification, no viable overload, ambiguous call, bad cast, branch join, return against signature, uninferrable declaration | X |
| non-constant clang builtin argument (SC108E), builtin used as a value (SC109E) | X |
| dependent conformance | ConformanceChecking, at the outer use |
| orphan violation | ExtensionOrphanCheck (not implemented) |
| access | AccessCheck |
| a declaration-scope `eval if` on a type fact that cannot be decided, waits on another forever, or reads a type parameter (SC132E) | EvalIfLateFolding |

Two declarations in sibling branches of one deferred `eval if` are never a redefinition (N(a)) or a redeclaration (R).

### Fact writers

Invariant 7 in full.

| Fact | Writer |
|---|---|
| `resolved_decl` / `candidate_cell` on heads | N |
| chain steps with declared bases | ChainBinding |
| chain steps needing inference | ChainBinding's `bind_step`, called by X |
| promotion of a candidate cell to one declaration | X |
| `canonical`, `type_flags`, segment slots, the `self` receiver type, `spec_kind` refinement, specialization chain links, `instantiated_from` on specializations | T |
| function redeclaration chains | R |
| `Expr::type_`, `value_category`, `expr_flags`, inferred declaration slots, `is_generator` / `has_yield` on FunctionDecl | X |
| `instantiated_from` on implicit nodes | the instantiation registry |
| `needs_using` | MemberLookup |
| `sc->bounds` | ConstraintExtraction |
| `default_thunk` / `pack_type` on ParamDecl | CallLowering |
| `init_fold` / `init_neg` / `init_mag` / `init_thunk` on FieldDecl | FieldInitLowering |
| `ci_split` / `ci_index` / `ci_slots` / `ci_dense` on FunctionDecl | CtorInitCheck |
| `ci_cut` on FunctionDecl | CtorInitLowering |
| `ConditionalStmt::eval_deferred`, `sc->eval_branches` | EvalIfFolding (filed in E, retired by EvalIfLateFolding) |
| `fold_pin` on VariableDecl / FieldDecl | EvalIfLateFolding |
| a transfer constructor's `other` mode; a record's derived `op =` (`assign_from`, `assign_form`); lifecycle facts | ClassLifecycle, one instance owned by `Sema`, published as `sc->lifecycle`; readers go through `lifecycle_of(sc)` |

## Remaining work

Open items of the Sema pipeline. Items owned by other stages are listed in their documents.

- ConstChecking is a stub: assignment to a `const` binding is caught by clang, not Sema.
- A type declared in a deferred `eval if` branch is refused.
- A type extent that reads a constant declared in a deferred `eval if` branch (`[u8; W]`) is resolved before the late fold decides which `W` exists.
- The late-fold agreement pin covers neither direct type facts with no constant nor constants of other TUs.
- `requires_holds` cannot decide the type-fact intrinsics, so the partial specialization SC132N suggests is undecided at use.
- `eval if T impl I` narrows only the steps ChainBinding binds; steps the expression typer binds and operators do not see it.
- MoveCheck ignores aliases of concrete MOVE values.
- MacroExpansion (E) is a stub.
- ExtensionOrphanCheck and the import-scoped extension index do not exist.
- ImportResolution reports three different errors under one code, R015E.
- `_register_specs_in` descends type and module scopes only, never executable scopes.
- InitCheck checks one rule (field defaults read only earlier fields) plus the static-field rules.
