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

#### A base that is a type parameter

A class may derive one of its own type parameters (`class <A derives B> M derives A`). The edge's canonical stays the `GenericParamType`, so Speller writes `: public A` and no per-instance base list exists. What the edge names is computed by `TypeUtil::param_edge_bases(of, e)` from the record that asks: the argument when `of` is an instance with a class argument; the class the parameter's `derives` bound names when the argument is itself a parameter (the class's own body, `M<U>` in another generic). The bound is read off the owner's requires clause (`TypeUtil::bound_classes`), not `SemaContext::bounds`, because the question is asked from every file that uses the class. `Substitution::base_through` answers a parameter edge this way, so `derives_from`, `base_records` and `bind_from_record` need no special case. ConformanceChecking refuses the forms a body cannot be checked against at the declaration (SC351E) and an argument that cannot be a base at the instance (SC352E: `final`, no default constructor, a member that hides a non-virtual member of the bound, a virtual destructor the bound lacks). A base initializer `A::A(self, ..)` is SC351E from ChainBinding. A partial specialization with a conformance bound is SC116E.

### Member types of a generic instance

A record nested in a generic record and named through an instance (`L<i32>::P`, `L<i32>::M::P`) is `RecordType(P, own args, outer = L<i32>)` (`CanonicalTypeStore::record_in`). The instance is part of its identity, so `L<i32>::P` and `L<f64>::P` are two types, and it is never a registry entry: C++ instantiates a member class with its enclosing instance. Inside `L`'s body `P` is the plain record flagged `InGenericOwner` (the current instantiation, not dependence).

The mechanism is substitution. `substitute` rebuilds a flagged record over its owner's bound arguments (`Substitution::_owner_through`), and `bind_own` of a record with an `outer` binds the enclosing instance's parameters, so `q.k` on `q: L<i32>::P` reads `K := i32`. T forms the type for a written `L<i32>::P` (`TypeResolve::_kairo_instance_of`); ChainBinding and MemberTyping do the same for an expression head (`L<i32>::P { .. }`, `L<i32>::Color::Red`); deduction unifies the enclosing instances (`fn <T> f(r: L<T>::P)`). Speller spells it through the instance (`::ns::L<int>::P`, `typename ::ns::L<T>::P` while dependent), EmitPlan admits the enclosing instance Complete wherever the member type is named, and ConformanceChecking makes it live.

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
| ConformanceChecking, a generic function read as a value (`pick<i32>`, `m::pick<i32>`) | `ConformanceChecking::_check_fn_value`: the use is an instantiation site, so its bounds are checked there as a call's are. X types the value by substitution only (`ExprTyper::generic_fn_value_type`) |
| CallLowering | default-argument thunks |
| foreign | `TypeImport`, `TypeExport` |

A call whose deduced arguments are dependent stores them in `CallExpr::dep_args` for the discovery walk.

Every mint goes through `_new_entry`, which inserts the entry into the worklist `_order` at its request key; `collect()` returns this order, never the hash table's. The key is the step of the one-thread schedule that asked and the asking group's request count, so the order is (TU order, mint order) and identical on every run, whichever thread mints first ([Parallel Sema](Performance.md#parallel-sema)). `InstanceEntry::seq` is the index at insertion and is not kept up to date.

### Instance nodes

A record instance (class, struct, union, enum, interface) is a shell: `spec_kind = Instantiated`, `instantiated_from = primary`, empty members and bases. Kairo shells are never filled. Member lookup, layout and the cycle check walk the pattern (`SemaContext::body_of`: the selected partial, else the primary), and members type through substitution. Only an imported template's instance is filled: the first lookup into it calls `ForeignInstantiate::fill` ([Interop.md](Interop.md#clang-integration)), after which it walks its own table; a failed fill is sticky and leaves it on the pattern. A function instance has no node: `_new_instance` returns the primary.

An explicit full specialization (`class <> Foo<i32> { ... }`) is registered by T through `register_explicit` once its arguments are canonical. It is its own declaration, checked as such, and never an instance. A record specialization is written in its primary's module; anywhere else no primary is visible to it (R042E), and the record is extended instead.
A full function specialization (`fn <> p<u8>() -> i32`) is paired with its primary by RedeclMerge (`_pair_specs`). With no primary in its own scope, one written at a file's top level is paired against the generic functions of that name the file's import overlay brings in (`_imported_prims`), so a module may specialize another module's function. Such a specialization is recorded build-wide (`InstantiationRegistry::register_fn_spec`, keyed by the primary's representative; `sweep_dead` drops a retracted one), and every TU of the compilation whose plan admits the primary admits it too (`EmitPlan::_admit_specs` through `Speller::fn_specs_of`). A TU that calls `p<u8>()` without importing the specializing module therefore declares the specialization, and the call runs its body. The specialization is declared and defined in the primary's namespace (`Speller::_home_dc`), and no explicit instantiation is written for the instance it defines.
What this cannot see: code compiled in another compilation than the specializing module. A library built or prebuilt without it (its own calls of `p<u8>` were instantiated from the primary when it was compiled), and a C++ translation unit that includes the primary's header but not the specializing module's, run the primary's body for those arguments; the specialization's strong definition and the library's instantiation then meet at the link, where one is kept. Two modules specializing one primary at the same arguments are not diagnosed by Kairo: both define the symbol, and the link reports it.

### Member specializations

A method of a generic class is specialized from an extension of the class, never in the class body (there it is SC116E, pointing at the extension forms). RedeclMerge pairs three forms with a class-body method `m` of the same name (`_pair_member_spec`, `_pair_instance_member`), setting `FunctionDecl::member_spec_of` to its representative:

| Form | Example | Applies to |
|---|---|---|
| A | `extend <T> G<T> { fn <> m<i32>(self) }` | `m<i32>` on every instance |
| B | `extend G<u8> { fn <U> m(self) }` (or a non-generic `m`) | every `m` on `G<u8>` |
| C | `extend G<u8> { fn <> m<i32>(self) }` | `m<i32>` on `G<u8>` |

The signature is the method's with the class's parameters read as the extension's (A) or the instance's arguments (B, C) and the method's own as the specialization's arguments (A, C) or its own parameters (B) (`_member_sig_matches`): parameter types and modes, return type, receiver constness, `static`, and the `unsafe` / `eval` / `panic` / `-> !` qualifiers. A and C that match no method, or more than one, are SC330E; a B member that does not match stays an ordinary extension member. Refused with SC116E: an extension whose target is a pattern other than the identity (`extend <T> G<T>`) or one instance; a constructor, a virtual or overriding method; a `requires` clause on the method or the extension; a pack or value parameter on the method or the class; a class nested in a generic one; an instance whose body is a partial or explicit record specialization. A member specialization is never a call candidate (OverloadResolution), so a B member is no overload beside `m`: every call names the class's method. Each pairing is recorded build-wide (`InstantiationRegistry::register_fn_spec`, keyed by the method), so a TU that calls `g.m<i32>()` without importing the specializing module sees it ([Codegen.md](Codegen.md#member-specializations)); code compiled in another compilation does not, as for function specializations.

Where an A (fixing `U`) and a B (fixing `T`) both apply to one instance and argument list, neither is more specialized; unless a C fixes that combination, it is SC333E, as are two that fix the same arguments. Reported by codegen in the method's own TU (EmitIR::_member_spec_dispatch), since the specializations may come from TUs that do not import one another.

### Function specializations

A full function specialization (`fn <> p<i32>() -> i32`) is C++'s explicit specialization of one primary template ([temp.expl.spec]). RedeclMerge pairs it after both of its merges, once each primary's representative is final (`RedeclMerge::_pair_specs`): the primary is a generic function of the same name in the same scope cell whose generic parameters the specialization's arguments fill one for one, and whose parameters, read with those arguments substituted (`Substitution::bind` on every link of the primary's chain), are the specialization's, mode for mode. The specialization must also agree on its return type (unless either side's is inferred from an expression body) and on `const`, `unsafe`, `async`, `eval`, `panic` and `-> !`. Pairing sets `instantiated_from` to the primary's representative; nothing is registered, because the specialization lives in its primary's scope and codegen finds it there (`Speller::fn_specs_of`).

| Case | Diagnostic |
|---|---|
| no generic function of that name in the scope, including a primary in another file | R042E |
| no primary matches, or more than one does | SC330E, a note at each candidate |
| a match that disagrees on its return type or a qualifier | SC330E, a note at the primary |
| a second specialization at the same arguments | linked as a redeclaration (`_link`): R029E for two definitions, R041E in a type body |
| a specialization inside a generic type or extension, or of an operator | SC116E |

A call never takes a specialization as a candidate (`OverloadResolution` skips it): it resolves to the primary and mints the primary's instance at the arguments, which is what Kairo types the call against. The body that runs is chosen by C++: codegen emits the specialization as `template <> R p<int>(...)` (`Speller::is_fn_spec`, `template_head`, `spec_suffix`), declared after its primary in tier 2 (`EmitPlan::_specs_after_primary`) and, for a member, after every primary in its class or extension scope. Every TU that admits a free primary admits its specializations (`EmitPlan::_admit_specs`), so a TU calling `p<int>` has seen the specialization; a member's are declared by its owner's definition. No explicit instantiation is written for an instance a specialization defines (`Speller::fn_spec_for`), and a specialization is never befriended on its own: the primary's friend template names it.

### Partial selection

Selection happens at mint (`_select`), never later. The registry does an exact structural match of each registered partial's canonical `spec_args` against the arguments (`register_partial`, registration order; no conversions, qualifiers must match exactly) and orders candidates by [temp.class.order], simplified. A dependent use (`Store<*P>`: an extension's receiver, a partial's own `Self`) selects the same way at lookup (`SemaContext::record_body`), its parameters opaque. A partial whose pattern holds a pack expansion (`Traits<Box<T>, Args...>`, `Traits<Tup<T...>>`) is SC116E at the first pack (`TypeResolve::_register_type_spec`, `PatternPackFinder`): `_match` binds one type per parameter and could never select it, while clang would. The result is kept on the entry (`pattern`, `pattern_args`); `instantiated_from` stays the primary, because every reader of that link asks which template the instance belongs to. `pattern_args` are the partial's own parameter bindings (`Store<*i32>` against `<P> Store<*P>` is `[i32]`), since `args` are in the primary's parameter space. A qualified argument is a pattern: the parser classifies `<P> V<const P>` as a partial, not as the primary form (`DeclParse::_is_simple_ident_type`), and matching strips the qualifier it matched, so `V<const i32>` against `<P> V<const P>` binds `P = i32`; `V<i32>` never matches it.

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
| `liveness` | `InstLiveness`: Minted (nothing has needed it), Live (a use needs it; its reach not walked yet), Walked (its reach has been walked). Past Minted exactly when `depth` is nonzero (a debug check in each transition); back to Minted only by a live check's re-arm | `mark_live`, `set_checked` |
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

The cycle state is the entry's (`liveness`), never the decl's, because every function instance shares its primary's decl. Each instance's rows are its own bounds' only; the walk checks each reached instance after the outer one's rows are written.

A use with no range (`var b = Box<M>(...)` visits the inferred type before the initializer) waits for a written use in the same TU and falls back to the enclosing range at the end of the TU. A reached instance inherits its root's `use_at`.

Depth limit: `--cmax-generic-depth` (`LangOptions::max_generic_depth`, default 128, minimum 1). The check is made before minting. Past it, SC160E "instantiation depth exceeds N: 'a' -> 'b' -> 'c' -> ... -> 'x' -> 'y' -> 'z'" (first three, last three) at the root's use, a note at the use in the deepest body, and a note naming the flag; once per root (`_too_deep_at`). Polymorphic recursion through a pointer (`*L<Wrap<T>>` in `L<T>`) hits this error although C++ accepts it.

`--cmax-generic-instantiations` is parsed into `FrontendOptions::max_generic_instantiations` and not read.

### Homing

The emitted home is codegen's (D3): the TUs whose plan admits the instance are its users, and the home is the least module path among the users that import no other user, which is the first namer below with the entry's sibling import order replaced by the module path, so the home does not move with the entry. Instances that are one C++ entity (same primary declaration, same arguments once `usize`/`isize` are folded) share a home. The primary is identified by its declaration, never by its source position: every declaration a macro invocation makes is at that invocation. Sema's home is the home its first request in the one-thread schedule named (`home_fid`; with parallel Sema a later request with a smaller key takes it over, see [Parallel Sema](Performance.md#parallel-sema)). For direct naming the first namer is the template's own TU when it uses the instance, else the first user in DAG order; an instance minted by substitution or by the walk is homed in the minting TU. An instance no tree names is reached through the `reached` edge: every plan holding the outer instance follows it transitively (and from a member template of a class template), and admits the reached instances and their rows. A sweep that admits every entry homed in a TU is deliberately not used: it would write explicit instantiations for instances minted only by substitution into losing candidates, and an explicit class instantiation instantiates every member, where a bounded record's concept can fail.

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

Value predicates, kind bounds and conformance are checked in Kairo at the instantiation site before emission (`ConformanceChecking::_bound_rows`): a top-level `P impl I` is SC162E, `P derives B` SC156E, a kind bound SC292E, and every other conjunct of a function's or a record's clause is evaluated at the instance's arguments (`_value_preds_ok`); one known false is SC300E at the use, with a note on the conjunct saying why (`'A' implements 'I'`, `'A' does not implement 'I': it has no 'm'`, both sides of a false `||`). The evaluator (`_vp` / `_pred_false`) decides literals, `sizeof` / `alignof` of builtins and pointers, arithmetic, comparisons, `!`, `&&`, `||`, parentheses, the triviality facts, and `P impl I` / `P derives B` as truth values (`_constraint_vp`: the conformance table and the argument's bases). A conformance that fails only because its witness is hidden from the file (a member that is not `pub`, an extension not imported) is undecided, because the emitted C++ concept can still see the witness (see [Hidden witnesses](#hidden-witnesses)). A conformance of an argument whose type is a parameter of the enclosing generic (an open type, at a call in a generic body) holds when that parameter's declared bounds grant it: a bound that is the interface, or an interface deriving a non-generic one; for `derives`, a base that is or derives the base (`_open_bound_holds`). It is never known false there. Anything undecided is left to the emitted C++.

The emitted template carries the constraints codegen derives: `requires I_c<...>` per interface bound, a record's self-contained value predicates, and a generic function's value predicates when every one spells in C++ (`Speller::fn_preds_in_head`, `P impl I` spelled `I_c<P>`), else the function's are its body's `static_assert`s. They hold for every instance Kairo accepted and are the only check for instances only C++ sees.

### Selection by `requires`

A generic candidate whose clause is known false for its deduced arguments is not viable (`OverloadResolution::_requires_filter`, after every candidate is judged, before ranking): `requires T impl I` beside `requires !(T impl I)` never tie, nor do `sizeof T <= 4` and `sizeof T > 4`. Inline bounds are conjuncts after `RequiresDesugar`, so a failed `<T impl I>` counts the same. An undecided clause leaves the candidate viable. When the clause is the only thing against the one viable candidate it stays selected and the instance check reports it (SC162E / SC300E); with several, each rejection is a note of SC063E. Because a function's clause is in its template head, C++ selects the same overload from the same clauses.

#### Ordering by constraints

Two generic candidates still tied after partial ordering are ordered by their constraints, as C++ orders them ([temp.func.order]/6, [temp.constr.order]); `OverloadResolution::_more_specialized`, `ConformanceChecking::more_constrained`. The rule applies only when all of these hold:

- each candidate is at least as specialized as the other, and their template heads are equivalent: as many generic parameters, of the same kinds, and the second's parameters deduce from the first's parameter types position for position (`_equivalent_heads`; `(a: A, b: B)` against `<B, A> (a: A, b: B)` is not equivalent);
- both clauses are known to hold for the call's arguments (`_clause_open`, `ConformanceChecking::clause_decided_true`): C++ orders candidates only after their clauses have admitted both, so a clause Kairo cannot decide (an open parameter in a generic body, the `sizeof` of a class) may be false where C++ decides it;
- the function parameter lists have the same length, defaulted parameters included ([temp.over.link]);
- both clauses are made only of what the C++ head carries (`_in_cxx_head`): conformances to a concrete interface and value predicates over literals, value parameters, `sizeof` and `alignof` under builtin operators. A `derives` test, a call or a trait test is not in the head, so overloads told apart only by one would be one C++ template.

A candidate is at least as constrained as another when the other has no clause, or both have one and its clause subsumes the other's: every clause of its disjunctive normal form shares an atom with every clause of the other's conjunctive normal form. More constrained means at least as constrained one way only. Atoms are compared as C++ compares atomic constraints: `P impl I` with a concrete `I` is one atom wherever it is written (it is the concept `I_c<P>`, normalized to the concept's definition), identified by P's position in the candidate's parameter list, or by the parameter itself when it belongs to an enclosing record; every other atom (a negation, a value predicate, a dependent bound) is identified by where it is written, so `!(T impl I)` in one overload is never the same atom as in another. A normal form past `CLAUSE_NORMAL_MAX` (256) clauses orders nothing. So `requires T impl I` beats no clause, `<T impl I>` beats no clause, `requires T impl I && T impl J` beats `requires T impl I`, and `requires T impl I` beats `requires T impl I || T impl J`; `requires T impl I` beside `requires T impl J` stays SC064E, and so does `requires !(T impl I)` beside `requires !(T impl I) && T impl J`. An interface's concept does not conjoin its bases' concepts (Witnesses.md), so `T impl Derived` does not subsume `T impl Base`, in Kairo or in C++.

#### Calls in a generic body

A generic body is checked against its bounds (`generics.mdx`), so a call there is resolved by them, not per instance. With the open-parameter rule above, a bound decides a candidate's conformance: in `fn <T impl Loud> relay(x: T) = say(x)`, `requires T impl Loud` holds and `requires !(T impl Loud)` is false, so the first `say` is selected where the call is written; C++ selects the same one at each instance from the heads. A tie that remains among candidates whose clauses test an open parameter is SC320E (`OverloadResolution::_report_open_tie`), not SC064E: a note per candidate names the bound that selects it (`T impl I`), says the interface is not public when the calling file cannot name it, or says that no bound can select it (a negated conformance, a value predicate, or no clause beside a constrained one). `std::copy` from a generic body is such a call: its first overload needs `T impl CopiesItself`, which is not public, and its second needs `!(T impl CopiesItself)`, which no bound promises.

#### Hidden witnesses

A conformance whose witness the calling file cannot use (a member that is not `pub` in a type whose file declares no `impl`, an extension not imported) is undecided rather than false, because the emitted C++ can still see that witness: an unmarked member is `public:` in its module's own object, a `prot` member of a module is `public:` everywhere, and another header may bring in a witness specialization. Deciding it false would let clang call an overload Kairo did not. When such a conformance is what keeps candidates tied, the call is SC162E naming the member and the interface it would implement, with a note on the test that tells the overloads apart and a fix-it making the member `pub` (`ConformanceChecking::report_hidden_tie`), in place of SC064E; for an extension the row records as hidden, the note names the extension's file to import. An extension member that member lookup does not return at all leaves no hidden witness: the conformance is false in Kairo, and the C++ TU, which has no witness specialization for it, agrees (`std::copy` then uses the copy constructor).

A member's `requires P impl I`, with P a parameter of its record, is the member's own: ChainBinding gives the member's body I's members on P (as a taken `eval if P impl I` branch does), Speller::member_requires emits the conjunct as the member's trailing C++ constraint so an instance that does not conform has no such member and the body is never instantiated there, and a call of the member on such an instance, or a subscript through a constrained `op []` / `op []=`, is SC153E (`ConformanceChecking::_check_member_requires_on`). A call from a generic body whose own bounds do not promise the clause is not checked in Kairo; clang rejects that instance.

Instances from different TUs share one registry and one table of rows, so a TU that uses an instance another TU made live re-checks its bounds against its own imports ([Interfaces.md](Interfaces.md#conformance)).

Template member bodies are emitted in the template's own TU and in every TU that homes one of its instances, since an explicit instantiation definition needs the body visible; the header carries them. An explicit instantiation instantiates only the members defined where it appears, so the definitions are emitted after every body in the TU (`InterfaceEmitter::emit_home_instantiations`, a second pass after `EmitIR::emit_tu`). Emitted with the preamble, the instance would have no members, the importer's `extern template` would refuse to supply them, and the link would fail with no diagnostic. An instance over a value argument C++ computes gets no explicit instantiation line ([Codegen.md](Codegen.md#templates)).

### Conditional extensions

An extension's `requires` clause whose `&&` operands include `__builtin_is_declared<P>()` makes the extension conditional (`ExtensionDecl::gate`: the paths, the declarations they named, `local`). It is decided in phase E of the extension's file by `DeclaredQueryFolding` ([NameResolution.md](NameResolution.md#declared-query-folding)); the clause's other operands are treated as any extension's are. Only a direct operand of the `&&` chain counts: the query under `!` or `||` is SC342E, and a query reached through an `eval fn` the clause calls folds in the file that wrote the `eval fn`, so it does not make the extension conditional. `impl` on a conditional extension is SC342E; a public member of a conditional block still meets an interface requirement structurally, in the files that see the block, with the witness in the using file's unit only. The query in an `eval if` of a type's body is SC342E: a type has one member list in every file that sees it.

The extension's own file decides the block once. Each path is looked up in the file's own scope, then in every C++ header of the build (`DeclaredQuery::resolve_in_headers`, [Interop.md](Interop.md#cxxstd)).

- All found: the block is live. A path only the headers declare is bound in the block's own scope to exactly that declaration, so `cxx::std::string` resolves there and `cxx::std::move` does not unless the clause asks about it. The block is then resolved and type-checked like any other, and its errors are reported in the extension's file.
- One found nowhere: the block is dropped like an untaken `eval if`; nothing in it is resolved.

A class, struct or union that is only forward-declared, and an alias of one, does not count as declared (`FFILinkage::ffi_defined`): `<iosfwd>` alone does not make `cxx::std::string` declared. Completeness is the build's and the name is the file's: a file whose own headers only name `std::string` (through `<iosfwd>`) still sees the block when another file of the same build includes a header that defines it, since C++ sees one merged header set per build.

Each file that sees the extension then asks, through MemberLookup's visibility filter, whether every path resolves in its own scope to the same declaration ([MemberLookup.md](MemberLookup.md#visibility)). Sema runs in import order, so the block is finished before any importer starts; the per-file answer needs no re-check because C++ headers are indexed before any Kairo Sema and a header entity is one Kairo declaration build-wide. One declaration, one resolution, one scope text: visibility is a filter on an identity the build fixes, and in another build the block is the same block or absent. The block's members use each other freely; unconditional code of the extension's file that uses one is SC343E ([SemanticChecks.md](SemanticChecks.md#conditionalextensioncheck)). `extend <T> Vector<T> requires __builtin_is_declared<cxx::std::vector>()` and `... && T impl X` are conditional generic extensions.
