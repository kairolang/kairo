# Generics

How the compiler checks, enumerates and instantiates generic declarations. The language rules are in the language reference (`generics.mdx`, `requires.mdx`, `where.mdx`); conformance and associated types are in [Interfaces.md](Interfaces.md); the C++ spelling of templates and instances is in [Codegen.md](Codegen.md#templates); calls through a bound are in [Witnesses.md](Witnesses.md).

## Instantiation model

Kairo has no monomorphizer. A generic body is checked once, at its definition, against its bounds. Sema enumerates every instance it can see and computes per-instance facts by substitution; it never clones or re-types a body. Codegen emits every generic as one C++ template and every enumerated instance as an explicit instantiation.

### Decisions

| Id | Decision | Rationale |
|---|---|---|
| D0 | A body is checked once against its bounds; no per-instance re-check. Per-instance work is the instance-facts pass ([M2](#monomorphization-sync-point)): facts computed by substituting the arguments into what the bounds declare. | A per-instance Kairo check could only produce diagnostics, never different code (D2). Re-typing a lowered, shared body is not possible: `ExprTyper` writes its results onto the nodes and memoizes by node pointer. The language reference already states the rule. |
| D2 | Anything that differs per instance and reaches codegen is selected by C++ itself: a trait specialization, a `requires`-constrained partial, `if constexpr`, an overloaded helper. Sema predicts, C++ decides, a `static_assert` pins the prediction. | kcc hosts, C++ templates (`std::sort` with a Kairo comparator) and coroutine promises instantiate Kairo generics at types Kairo never enumerates. |
| D3 | An instance's Sema home is its first namer in the one-thread schedule (`InstanceEntry::home_fid`, deterministic TU order, whichever thread asks first); it orders the M1 worklist. The TU that writes its explicit instantiation is codegen's choice (`EmitPlan::assign_homes`, [Incremental.md](Incremental.md#shared-across-graphs)): among the TUs whose plan admits it, in the Sema home's root, the least module path among those that import no other. Facts are computed once and read from the registry everywhere. | Homing must be the same on every run, and in every graph that holds the TU (one object cache serves every tool). |
| D4 | Instance discovery is a worklist fixpoint in deterministic order; depth is a reported limit. | See [M1](#m1-enumeration). |
| D5 | A generic body's panic set is computed at its definition from the bounds' declared sets. | See [Panic facts](#panic-facts). |
| D6 | A diagnostic about an instance is reported at the use that made it live, with one note per instantiation hop. | See [Instance diagnostics](#instance-diagnostics). |
| D7 | Conformance rows are program-wide facts on the instance; visibility is a per-TU filter. | Every TU emitting `X<A> impl I` must emit the same rows (ODR). See [Interfaces.md](Interfaces.md#conformance). |

### Body regimes

A generic parameter's regime is its declaration's (`GenericParamDecl::kind_bound` and the bounds in `SemaContext::bounds`).

| Regime | Written | Member step on `T` | Operators, conversions, f-strings, `match`, null tests |
|---|---|---|---|
| Opaque | `<T>` | R051E "'T' has no members", note suggesting a bound | error at the definition: R051E; an f-string hole defers to the instance |
| Bounded | `<T impl I>`, `<T derives B>` | binds the bound's requirement or base member (ChainBinding) | the bounds' requirements (interfaces, then bases: `TypeUtil::bound_scopes`), else R025E; an f-string hole no bound formats defers to the instance |

The definition-time rules for opaque and bounded parameters key on one predicate, `TypeUtil::checked_param` (a bare, non-pack-element `GenericParamType` that has no `derives` bound), and its generalizations: `op_checked_param` admits a `derives`-bounded parameter for operators, and `checked_head` admits an associated type. A dependent composite (`*T`, `[T]`, `Holder<T>`) keeps its own rules.

| Construct on a checked `T` | Rule | Code |
|---|---|---|
| binary, unary, compound, `^^` | the bounds' requirement (witness call), else an error naming what grants it (`'!=' ... 'op !=' or 'op =='`, relational `or 'op <=>'`, `+` `or 'op +='`) | R051E unbounded, R025E bounded; `1 + t` with `T` on the right SC066E; `&&`/`\|\|` SC067E |
| `===` on `T?` | the bounds' `op ==`; the pointee rule never applies through `T` | R051E / R025E; never-nullable operands SC034E |
| `t?`, `t == null`, `unwrap!(t)` | a checked `T` is never nullable | the ordinary non-nullable errors |
| `as X` | `op as` looked up in the bounds (CastTyping), lowered to a witness call (`__kairo_op_as_<target>`) | R051E / R025E |
| f-string hole | `repr`, then `op as` returning `string`, in the bounds (`LiteralTyping::_string_conv`); with neither, the hole is deferred and each instance picks its put ([FormatStrings.md](FormatStrings.md#lowering)) | none at the definition; an instance with no formatter fails in C++ |
| `match` | only a binder, `_`, `default` and `where` guards; the domain is opaque (PatternSpace), exhaustive when an unguarded binder, `_` or `default` ends it | other patterns SC257E; non-exhaustive SC120E |
| `T{}`, `T(args)` on an associated type | needs a constructor requirement of that arity in the associated type's bounds; a field list is always an error | SC251E |

A generic ADT at dependent arguments is not opaque: a `match` on `Rep<T>` resolves against `Rep`'s variants (`PatternTyping::dependent_adt`), is checked for exhaustiveness, and tests the tag through `__kairo_which()`. `==` on two values of one such instance whose enum declares no `op ==` or `op <=>` is the tag compare. A pack-expanded variant at a dependent type is SC116E.

`T{}`, `T()` and `var x: T` with no constructor bound on a plain parameter are accepted with no check.

### Substitution

`Substitution` (`Compiler/Sema/Type/Substitution.k`) is the one substituter. `Deduction` (`Compiler/Sema/Type/ArgumentDeduction.k`) derives from it and adds unification. Every per-instance fact in this document is a `Substitution` seeded by `bind_from_record(instance)` or by a call's deduced arguments. `bind_from_record` binds the record's own parameters (the primary's and the selected partial's), then every generic base's, read through its arguments hop by hop, so a member a generic base declares (`s.me()` on `class Seven derives Mixin<Seven>`) reads at the base instance; `bind_own` is the first half alone.

| Entry point | Job |
|---|---|
| `substitute(t)` | substitutes bound parameters; a substituted record type that comes out concrete is minted in the registry. A Kairo default argument naming earlier parameters is substituted (`<K, V = K>`: `Pair<i32>` is `Pair<i32, i32>`); a foreign one that is still dependent stands in. |
| `derives_from(derived, base)` | derived-to-base on types, for every implicit upcast, `as`, and the downcast hint: the base list is `SemaContext::record_body`'s (a filled instance's own, a selected partial's, else the pattern's), substituted per hop, so `Const<i32>` of `derives Source<T>` reaches `Source<i32>`. `*Const<U>` to `*Source<V>` does not pass on decl identity. |
| `member_through(recv, t)` | a member's type as seen through a receiver instance. |
| `replace_self` | `Self` replaced by a conformer; a concrete record it builds goes through the registry. |
| `assoc_witness`, `assoc_type`, `bound_ifaces` | associated types ([Interfaces.md](Interfaces.md#associated-types)). |
| `bind_alpha(to, from)` | binds one declaration's generic parameters to another's, for alpha-equivalence ([where groups](#where-groups-on-generic-functions)). |

Applications of substitution that the type checker relies on:

- Receiver seeding: a primary's own constructor, static or method called on a concrete instance is ranked with the instance's arguments bound, as a selected partial's members are. An inherited member of a generic base is not seeded.
- A static member named through a generic record writes `CallExpr::qualifier` (CallTyping); CallLowering's thunk path reads it and EmitPlan admits it Complete.
- A generic alias application `Mat<i32>` is the aliased type substituted at the arguments, concrete or dependent; it is instantiation-dependent only when substitution fails.
- A bound call's result. With no written qualifier, OverloadResolution's `_judge` seeds the requirement's interface parameters from the first interface bound of the receiver parameter whose `declaring_instance` reaches the candidate (`TypeUtil::bound_ifaces`, `derives` chain included). The result is an ordinary value: members bind, initializers and returns are checked, and arguments are ranked against the bound's types. Operators and `op []` through a bound resolve through the same path. A non-generic interface binds nothing and is not seeded. When two bounds declare one requirement at different arguments, the first bound wins.

### Member types of a generic instance

A record nested in a generic record and named through an instance (`L<i32>::P`, `L<i32>::M::P`) is `RecordType(P, own args, outer = L<i32>)` (`CanonicalTypeStore::record_in`). The instance is part of its identity, so `L<i32>::P` and `L<f64>::P` are two types, and it is never a registry entry: C++ instantiates a member class with its enclosing instance. Inside `L`'s body `P` is the plain record flagged `InGenericOwner` (the current instantiation, not dependence).

The mechanism is substitution. `substitute` rebuilds a flagged record over its owner's bound arguments (`Substitution::_owner_through`), and `bind_own` of a record with an `outer` binds the enclosing instance's parameters, so `q.k` on `q: L<i32>::P` reads `K := i32`. T forms the type for a written `L<i32>::P` (`TypeResolve::_kairo_instance_of`); ChainBinding and MemberTyping do the same for an expression head (`L<i32>::P { .. }`, `L<i32>::Color::Red`); deduction unifies the enclosing instances (`fn <T> f(r: L<T>::P)`). CXXSpell spells it through the instance (`::ns::L<int>::P`, `typename ::ns::L<T>::P` while dependent), EmitPlan admits the enclosing instance Complete wherever the member type is named, and ConformanceChecking makes it live.

### Where groups on generic functions

A `where` group (`where.mdx`) whose members are generic folds into one dispatcher template; every guard is an ordinary run-time `if`, including a guard that reads only the parameters' types (`sizeof T > 4`). Under D0 every candidate is checked against the shared bounds and is well formed for every argument they admit, so a run-time test of a per-instance constant is correct and clang folds it. `if constexpr`, a `requires` overload set or a `static_assert` pin would buy only dead-code elimination.

- Grouping: `RedeclMerge::_alpha_same` treats two generic functions as one signature when they have the same number of parameters of the same kinds and their parameter types and modes agree after `bind_alpha`. It is asked only when one of the pair is guarded, so an unguarded declaration and its definition keep plain identity.
- `WhereGuardCheck` requires what one C++ signature needs: identical generic parameter names (guards move into the lead's template and still spell the member's names), identical bounds compared through `bind_alpha`, and alpha-equal return types. A second unguarded member is R029E.
- Lowering: a candidate takes its member's generic parameter list and requires clause, keeps its member's visibility (a module header instantiating the dispatcher must declare it) and is called with no template arguments; C++ deduces them from the dispatcher's parameters. No registry entry is minted for a candidate instance: the home's explicit instantiation of the dispatcher instantiates them implicitly.

A value or pack parameter, or a type parameter no parameter's type mentions, is SC116E. The lowering itself is [WhereDispatchLowering](Lowering.md#passes).

## Instantiation registry

`InstantiationRegistry` (`Compiler/AST/Context/InstantiationRegistry.k`) maps `(primary, canonical args)` to the declaration that is that instance. There is one per build, beside the `CanonicalTypeStore`, with its own arena (an instance first named by one TU is referenced by every importer and outlives that TU's arena) and a `SharedMutex`. It also holds the conformance table ([Interfaces.md](Interfaces.md#conformance)).

### Minting

`instance_for(primary, args, fid, ctx)` is get-or-create. Every argument must be canonical and non-dependent; a dependent use (`Foo<T>`, `Self` in a generic body) never reaches the registry, and its `RecordType::decl` is the primary. The instance node is created at naming time because a type needs a decl the moment it exists, and retargeting `RecordType::decl` later would break pointer identity.

| Minter | Site |
|---|---|
| T, written `Foo<i32>` | `TypeResolve` |
| ChainBinding | expression heads |
| X | types from decls; a call to a generic callee with fully concrete deduced arguments (`CallExpr::instance`) |
| Substitution | `Substitution::substitute`, whenever a substituted record comes out concrete |
| lang records | `SemaContext::lang_record` (`[i32;]`, `Slice<i32>` and a literal that took `[i32;]` are one instance) |
| discovery | `ConformanceChecking::_walk` |
| CallLowering | default-argument thunks |
| foreign | `TypeImport`, `TypeExport` |

A call whose deduced arguments are dependent stores them in `CallExpr::dep_args` for the discovery walk.

Every mint goes through `_new_entry`, which inserts the entry into the worklist `_order` at its request key; `collect()` returns this order, never the hash table's. The key is the step of the one-thread schedule that asked and the asking group's request count, so the order is (TU order, mint order) and identical on every run, whichever thread mints first ([Parallel Sema](Performance.md#parallel-sema)). `InstanceEntry::seq` is the index at insertion and is not kept up to date.

### Instance nodes

A record instance (class, struct, union, enum, interface) is a shell: `spec_kind = Instantiated`, `instantiated_from = primary`, empty members and bases. Kairo shells are never filled. Member lookup, layout and the cycle check walk the pattern (`SemaContext::body_of`: the selected partial, else the primary), and members type through substitution. Only an imported template's instance is filled: the first lookup into it calls `ForeignInstantiate::fill` ([Interop.md](Interop.md#clang-integration)), after which it walks its own table; a failed fill is sticky and leaves it on the pattern. A function instance has no node: `_new_instance` returns the primary.

An explicit full specialization (`class <> Foo<i32> { ... }`) is registered by T through `register_explicit` once its arguments are canonical. It is its own declaration, checked as such, and never an instance.

### Partial selection

Selection happens at mint (`_select`), never later. The registry does an exact structural match of each registered partial's canonical `spec_args` against the arguments (`register_partial`, registration order; no conversions, qualifiers must match exactly) and orders candidates by [temp.class.order], simplified. A dependent use (`Store<*P>`: an extension's receiver, a partial's own `Self`) selects the same way at lookup (`SemaContext::record_body`), its parameters opaque. A partial whose pattern holds a pack expansion (`Traits<Box<T>, Args...>`, `Traits<Tup<T...>>`) is SC116E at the first pack (`TypeResolve::_register_type_spec`, `PatternPackFinder`): `_match` binds one type per parameter and could never select it, while clang would. The result is kept on the entry (`pattern`, `pattern_args`); `instantiated_from` stays the primary, because every reader of that link asks which template the instance belongs to. `pattern_args` are the partial's own parameter bindings (`Store<*i32>` against `<P> Store<*P>` is `[i32]`), since `args` are in the primary's parameter space.

A partial with a `requires` clause is a candidate only where the clause holds at the bindings (`requires_holds`). The evaluator is AST-only, pure and lock-free, because it runs inside type formation under the registry lock. It decides integer and bool literals, `sizeof` / `alignof` of builtins, pointers and fixed arrays of them (through a bound parameter too), `+ - * / %`, comparisons, `!`, and short-circuit `&&` / `||` (a decided side can settle an undecided one). The identity-pattern form `<P> X<P> requires ...` is reclassified as a partial by N, and T resolves its clause in the partial's scope before registration.

| Outcome | Entry | Diagnostic |
|---|---|---|
| two partials match, neither more specialized | `ambiguous_a`, `ambiguous_b` | SC157E at a naming site, once (`ambiguity_reported`) |
| a matching partial's clause is undecided (a record's size, an `eval` call, a value parameter) | `undecided`; the partial is not selected | SC158E at the use, once (`undecided_reported`), so C++ never picks a body Kairo did not type against |
| a conformance conjunct in a selecting clause | | SC116E at the partial |

Ordering of two equivalent patterns: the one with a `requires` clause is more specialized; two with clauses are unordered and tie. C++ would order them by subsumption of atomic constraints; Kairo reports an ambiguity where C++ might pick, and never picks differently.

The partial is emitted with its clause, so C++ selects from the same predicate. Every body of a template with a requires-selected partial carries `static constexpr unsigned __kairo_spec` (0 for the primary, 1 + registration index for a partial; `LowerTargets::spec_tag`), and the home TU's explicit instantiation is followed by a `static_assert` comparing it with Sema's choice ([Codegen.md](Codegen.md#templates)).

### Entry fields

| Field | Meaning | Writer |
|---|---|---|
| `primary`, `args`, `decl`, `is_explicit` | identity; `args` canonical, packs flat | mint |
| `home_fid` | TU that first named it in the one-thread order ([D3](#decisions)) | mint; a request with a smaller key (`_claim`) |
| `ord_rank`, `ord_seq` | the smallest request key: the schedule step that asked and the group's request count ([Parallel Sema](Performance.md#parallel-sema)) | mint, `_claim` |
| `seq` | worklist index | `_new_entry` |
| `depth` | 0 not live; 1 named at a use; reacher + 1 when only a body reaches it | `mark_live` |
| `checked` | its reach has been walked | `set_checked` |
| `use_at` | the use that made its chain's root live, inherited down the chain | `mark_live` |
| `via`, `via_at` | the live instance whose body made it live, and the use in that body | `mark_live` |
| `reached`, `reached_by` | instances its body reaches (deduplicated, reach order); first reacher | `add_reach` |
| `rows`, `rows_done` | program-wide union of its bound rows ([D7](Interfaces.md#conformance)) | `add_rows` |
| `failed` | its bounds failed where it became live; never reported again | `mark_failed` |
| `pattern`, `pattern_args`, `ambiguous_*`, `undecided*` | partial selection | `_select_into` |
| `adt_shape`, `adt_size`, `payload_offset`, `type_ids`, `type_keys`, `type_names` | ADT layout facts | `EnumLayoutQuery::sweep` |
| `formed_at`, `formed_fid` | where a panic set was first formed | `PanicSets::note_formed` |
| `panic_result`, `panic_types`, `panic_done`, `panic_checked` | [panic facts](#panic-facts) | `PanicInstances`, `PanicEffectChecking` |
| `emitted` | explicit instantiation written | codegen |

## Monomorphization sync point

The Sema stages after the lowerings are M1 (`SemaPhase::MonoCollected`) and M2 (`SemaPhase::Complete`), the last two steps of `Sema::run_to` (`Compiler/Sema/Sema.k`). Their slot in the stage order is in [Pipeline.md](Pipeline.md#sema-pass-order). Neither is a build-wide sync point: both run per TU in DAG order, and later TUs keep minting into the locked registry, as every stage that mints does.

### M1: enumeration

`_stage_mono_collect` runs `ConformanceChecking::discover`, the discovery fixpoint. It creates nothing of its own; every instance was minted by an earlier stage.

1. An entry becomes live when a tree names it at a use (`ConformanceChecking::_check_instance` calls `mark_live` and checks its bounds once for the build). An entry minted only by substitution, for example into a losing overload candidate, is never live: its bounds are never checked and its body never walked.
2. `drain` returns the live, unwalked entries in worklist order. It is a full scan, because a later TU can make an old entry live.
3. `_walk` visits each one's primary body (for a record: its methods and its fields' types, by value or behind a pointer, since C++ checks a constrained template-id wherever it is named). Each call with `dep_args` and each dependent type is substituted with a `Deduction` seeded from the instance, minted, linked by `add_reach`, and made live one hop below, which checks its bounds.
4. Repeat until a walk makes nothing new live.

The fixpoint runs at the end of each TU's ConformanceChecking (before the Typed barrier, where its diagnostics belong) and again as M1, where it normally finds nothing. M1 builds a fresh ConformanceChecking, which indexes extensions lazily. After M1 every live instance's reach is in the registry.

The cycle state is the entry's (`checked`), never the decl's, because every function instance shares its primary's decl. Each instance's rows are its own bounds' only; the walk checks each reached instance after the outer one's rows are written.

A use with no range (`var b = Box<M>(...)` visits the inferred type before the initializer) waits for a written use in the same TU and falls back to the enclosing range at the end of the TU. A reached instance inherits its root's `use_at`.

Depth limit: `--cmax-generic-depth` (`LangOptions::max_generic_depth`, default 128, minimum 1). The check is made before minting. Past it, SC160E "instantiation depth exceeds N: 'a' -> 'b' -> 'c' -> ... -> 'x' -> 'y' -> 'z'" (first three, last three) at the root's use, a note at the use in the deepest body, and a note naming the flag; once per root (`_too_deep_at`). Polymorphic recursion through a pointer (`*L<Wrap<T>>` in `L<T>`) hits this error although C++ accepts it.

`--cmax-generic-instantiations` is parsed into `FrontendOptions::max_generic_instantiations` and not read.

### Homing

The emitted home is codegen's (D3): the TUs whose plan admits the instance are its users, and the home is the least module path among the users that import no other user, which is the first namer below with the entry's sibling import order replaced by the module path, so the home does not move with the entry. Sema's home is the home its first request in the one-thread schedule named (`home_fid`; with parallel Sema a later request with a smaller key takes it over, see [Parallel Sema](Performance.md#parallel-sema)). For direct naming the first namer is the template's own TU when it uses the instance, else the first user in DAG order; an instance minted by substitution or by the walk is homed in the minting TU. An instance no tree names is reached through the `reached` edge: every plan holding the outer instance follows it transitively (and from a member template of a class template), and admits the reached instances and their rows. A sweep that admits every entry homed in a TU is deliberately not used: it would write explicit instantiations for instances minted only by substitution into losing candidates, and an explicit class instantiation instantiates every member, where a bounded record's concept can fail.

A member template of a class template has no registry identity of its own (`Box<A>::pick<X>` and `Box<B>::pick<X>` are one entry) and gets no explicit instantiation; its body is instantiated implicitly wherever the owner is complete. How EmitPlan writes `template` in the home and `extern template` elsewhere is in [Codegen.md](Codegen.md#templates).

### M2: instance facts

`_stage_mono_instantiate` computes the facts D0 allows: values obtained by substituting an instance's arguments into what its bounds and declaration state. Each is predicted by Sema and pinned or selected in C++.

| Fact | Computed by | Where | Pinned by |
|---|---|---|---|
| ADT layout (shape, size, niche) | `EnumLayoutQuery::sweep` | end of the lowerings, again after panic facts | `static_assert(sizeof ...)` beside the instantiation ([Codegen.md](Codegen.md#templates)) |
| lifecycle category and rules | `ClassLifecycle` | on demand, memoized per instance decl; rules asked when the instance becomes live | none needed: consumed by checks only ([Ownership.md](Ownership.md#move-only-types)) |
| conformance rows | ConformanceChecking | when the instance becomes live, and per TU on reuse | witness specializations ([Interfaces.md](Interfaces.md#conformance)) |
| panic result and the panic types its body forms | `PanicInstances` | M2 | `static_assert` against the alias at the instance |
| `requires` partial choice | the registry | at mint | `__kairo_spec` |

#### Panic facts

A generic body's panic set is computed once at its definition, naming its parameters; a call substitutes the requirement's, the generic function's or the method's declared set at the call's arguments ([Panic.md](Panic.md#passes)). M2's part is `PanicInstances` (`Compiler/Sema/Lower/PanicLowering.k`), run over live entries: the function's `Panic<T, E...>` at the arguments (`panic_result`, spelled by the explicit instantiation) and every dependent panic result its body names (`panic_types`, admitted Complete by EmitPlan so their elements' `__kairo_tid` specializations are written). The layout sweep then runs again. `PanicEffectChecking` checks each instance once (`panic_checked`) for duplicate `try` arms that name one type only at the instance. A member template of a generic class gets no panic facts (its entry holds only its own arguments).

### Instance diagnostics

An error about an instance (an unmet bound, a failed lifecycle rule, an undecided partial, a use after move found at the instance) is reported at `use_at`, the use that made its chain's root live. `ConformanceChecking::chain_notes` appends one note per hop, innermost first (clang's order), each at `via_at`: "in instantiation of 'inner<Wrap<Metric>>' required here". The root gets no hop note. Record-type hops (a field's `Box<T>`, a body's `Wrap<T>`) get notes too.

`--cmax-generic-backtrace` (default 5, 0 for all) caps the notes: past N hops, the first ceil(N/2), one note "K more instantiations in the chain; --cmax-generic-backtrace=0 shows them all", then the last floor(N/2).

An instance's bounds are checked once for the build, when it becomes live, so a second use of a failing instance, or a second chain reaching it, reports nothing. The depth error names its chain in the message and has no hop notes.

## Generics across modules

Each enumerated `(template, canonical args)` has exactly one explicit instantiation definition in the build, in its home TU; every other TU that holds it writes an explicit instantiation declaration. Zero definitions is a link error, so the registry is authoritative.

```text
home TU   : template <typename T> T add(T, T) { ... }   // body
            template i32 add<i32>(i32, i32);            // explicit instantiation definition
other TUs : template <typename T> T add(T, T);          // signature
            extern template i32 add<i32>(i32, i32);     // explicit instantiation declaration
```

Value predicates, kind bounds and conformance are checked in Kairo at the instantiation site before emission. The emitted template carries only the constraints codegen derives (`requires I_c<...>` per interface bound, a record's self-contained value predicates); they hold for every instance Kairo accepted and are the only check for instances only C++ sees. Kind bounds (`: class`, `: struct`, `: enum`, `: union`) are parsed and not checked.

Instances from different TUs share one registry and one table of rows, so a TU that uses an instance another TU made live re-checks its bounds against its own imports ([Interfaces.md](Interfaces.md#conformance)).

Template member bodies are emitted in the template's own TU and in every TU that homes one of its instances, since an explicit instantiation definition needs the body visible; the header carries them. An explicit instantiation instantiates only the members defined where it appears, so the definitions are emitted after every body in the TU (`InterfaceEmitter::emit_home_instantiations`, a second pass after `EmitIR::emit_tu`). Emitted with the preamble, the instance would have no members, the importer's `extern template` would refuse to supply them, and the link would fail with no diagnostic. An instance over a value argument C++ computes gets no explicit instantiation line ([Codegen.md](Codegen.md#templates)).
