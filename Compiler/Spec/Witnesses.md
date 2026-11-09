# Witnesses

A generic body that calls through an interface bound reaches the conformer's implementation through a witness: a C++ class template keyed on the conforming type. This document specifies its C++ shape, how a call site names it, and where each piece is emitted. Implemented in `Compiler/Codegen/Emit/EmitWitness.k`; the plan entries are `WitnessPiece`s in `Compiler/Codegen/EmitPlan.k`.

Sema's side is specified elsewhere: the conformance table and its rows (`ConformanceRow`, ConformanceChecking) in [Interfaces.md](Interfaces.md#conformance), interface composition in [Interfaces.md](Interfaces.md#interface-algebra), associated types in [Interfaces.md](Interfaces.md#associated-types), and the instance registry in [Generics.md](Generics.md#instantiation-registry).

## The problem

A generic body is emitted once, as a C++ template ([Codegen.md](Codegen.md#templates)). Kairo conformance is structural and may be supplied by an extension member, which is a static member of the extension scope `N::__kairo_ext_X` ([Codegen.md](Codegen.md#emitplan)), never a C++ member of `X`. No single C++ spelling inside a template reaches a different static function per `T`:

- `a.scale(2)` finds members only;
- an unqualified `scale(&a, 2)` finds nothing at definition, and ADL at instantiation searches X's namespace, not the scope struct;
- qualifying the call hardcodes one conformer.

The witness is a class template keyed on the conformer, so C++ specialization selection performs the per-`T` dispatch. After inlining it costs nothing.

## The C++ shape

Each interface has one primary witness and one concept. Each conformance the primary cannot serve has one specialization. For

    pub interface Scalable { fn scale(const self, factor: i32) -> i32 }
    pub struct Metric { pub var base: i32 }
    extend Metric { pub fn scale(const self, factor: i32) -> i32 = self.base * factor }
    pub fn <T impl Scalable> twice(a: T) -> i32 = a.scale(2)

in module `ring`, the emitted C++ is:

    namespace ring {
        template <class __kairo_Self> struct Scalable_witness {
            static signed int scale(const __kairo_Self* self, signed int factor) noexcept
                requires requires { static_cast<auto (__kairo_Self::*)(signed int) const -> signed int>(&__kairo_Self::scale); }
            { return self->scale(static_cast<decltype(factor)&&>(factor)); }
        };
        template <class __kairo_Self> concept Scalable_c =
            requires (const __kairo_Self* s, signed int a0) { ::ring::Scalable_witness<__kairo_Self>::scale(s, a0); };
        template <> struct Scalable_witness<::ring::Metric> {
            static signed int scale(const ::ring::Metric* self, signed int factor) noexcept
            { return ::ring::__kairo_ext_Metric::scale(self, static_cast<decltype(factor)&&>(factor)); }
        };
        template <class T> requires (::ring::Scalable_c<T>) signed int twice(T a);
    }
    ...
    namespace ring {
        template <class T> requires (::ring::Scalable_c<T>) inline signed int twice(T a)
        { return ::ring::Scalable_witness<T>::scale(&a, 2); }
    }

The names come from `LowerTargets::witness_suffix` / `concept_suffix` (`_witness`, `_c`) and `witness_self` (`__kairo_Self`), in `Compiler/AST/LangItems.k`. A generic interface keys its witness on `<__kairo_Self, A...>`, its own parameters after Self, so `impl Container<i32>` and `impl Container<string>` on one type are two specializations. This is why an interface bound must name every interface argument: the call site spells them. An interface with a value parameter is not built (EmitWitness ICEs).

### The primary

The primary forwards each requirement to a member of `__kairo_Self`, so a conformer whose requirements are its own methods (a Kairo class, an inherited member, an imported C++ class) needs no specialization, and a C++ host that instantiates a Kairo template with its own class gets a witness Kairo never saw.

Each forwarder is constrained on an exact match, a cast of `&__kairo_Self::m` to the requirement's member-pointer type (`auto (S::*)(P...) const -> R`, return type trailing so a parenthesized return spelling cannot split the declarator). A static requirement is gated on a plain function pointer, `auto (*)(P...) -> R`. The constraint is exact so that a specialization a Kairo TU emits can never be replaced by a primary that also compiles: with a callable-form constraint, a Metric with an own `scale(i64)` and an extension `scale(i32)` would bind the extension in a TU that sees the specialization and the own member in a C++ TU that does not, the same `twice<Metric>` compiled two ways, ill-formed with no diagnostic ([temp.expl.spec]/7). With the exact match the second TU fails at its call, through the concept. A member-pointer cast admits a base's member and a `noexcept` one.

A generic requirement has no member pointer to cast without its arguments. Its forwarder is a member template gated on the callable form (`self->template m<U>(...)`), the one place the hazard above remains.

The primary leaves out every member whose signature names an associated type, and declares no associated type itself (see [Associated types](#associated-types)).

### Witness members

Every witness member is declared as the requirement would be declared as an extension member of `__kairo_Self`, so the call site uses ExtensionLowering's receiver rules unchanged and there is one receiver convention ([Call sites](#call-sites)).

| Requirement | Witness member | Forwards to (primary / specialization) |
|---|---|---|
| `fn m(self, p: P) -> R` | `static R m(S* self, P p)` | `self->m(p)` / `::N::__kairo_ext_X::m(self, p)` |
| `fn m(const self, p: P) -> R` | `static R m(const S* self, P p)` | the same, const |
| `fn op ==(const self, o: Self)` | `static bool __kairo_op_eq(const S& self, S o)` | `self.operator==(o)` / `__kairo_ext_X::__kairo_op_eq(self, o)` |
| `fn op in(const self, x: T)` | `static bool __kairo_contains(const S& self, T x)` | `self.__kairo_contains(x)` / the scope's |
| postfix `fn op ++(self)` | `static R __kairo_op_postinc(S& self, int __kairo_pf)` | the dummy forwarded as is |
| `static fn make() -> Self` | `static S make()` | `S::make()` / `__kairo_ext_X::make()` |
| `fn <U> m(self, u: U)` | `template <class U> static void m(S* self, U u)` | `self->template m<U>(u)` / `__kairo_ext_X::m<U>(self, u)` |
| `fn op [](const self, k: K)` | `static R __kairo_op_index(const S& self, K k)` | `self.operator[](k)` in both |
| `fn <U> op +(const self, u: U)` | `template <class U> static R __kairo_op_plus(const S& self, U u)` | `self.template operator+<U>(u)` / `__kairo_ext_X::__kairo_op_plus<U>(self, u)` |
| constructor `fn I(self, ...)` | none | see [Constructor requirements](#constructor-requirements) |
| `type Node` | none in the primary | see [Associated types](#associated-types) |

`S` abbreviates `__kairo_Self`. The receiver is `self` or `const self` and nothing else (the receiver is never marked, [functions-parameter-modes](README.md#language-reference)), so `[const ]S*`, or `[const ]S&` for an operator (`CXXSpell::ext_receiver`), covers every case. An operator member is named by `LowerTargets::ext_op` (a static member cannot be `operator==`), or by its LowerTargets name for `in`, `^^`, `await`, `spawn`, `thread`: the name `CXXSpell::operator_name` gives an extension member. `op []` is member-only and has no extension name; its witness member is `LowerTargets::witness_subscript()` (`__kairo_op_index`).

Parameters are spelled by `CXXSpell::param_decl` and returns by `return_spelling` (a panicking requirement's by its `panic_result`), each with Self replaced by the witness's Self. Every argument is forwarded as `static_cast<decltype(p)&&>(p)`, as operator forwarders are, so a by-value parameter costs one move before inlining and is never copied. A witness member carries the requirement's calling convention and is `noexcept` unless the TU compiles with `-funwind`: a static thunk's address may become an `unsafe fn` value, whose pointer type is `noexcept`.

### Constructor requirements

Constructors never go through the witness. An extension cannot add a constructor ([extends](README.md#language-reference)), so every constructor requirement is met by an own constructor and `T(args)` / `T{}` is already the right C++ for every conformer. Lifecycle requirements (`@copy` / `@move` constructors) are C++'s implicit special members. The concept still lists each constructor requirement (`__kairo_Self(a0, ...)`, arguments forwarded so a `@move` requirement asks for a move constructor), so a host's non-conforming class fails at the call.

A primitive satisfies no constructor requirement: `i32()` is not a call in Kairo (SC037E), so `i32` has no constructor for a row to name, though C++ `int()` compiles. A record with no declared constructor meets a zero-parameter one, as `S()` types.

### Specializations

A non-generic conformance gets a full specialization (`template <>`). A generic declared conformance (`extend <E> Wrap<E> impl I`, `class <T> Box impl I`) gets one partial specialization, its conformer over the declaring decl's own parameters (`ConformanceRow::declared`), headed by that decl's `CXXSpell::template_head`. The head includes interface bounds, so a conditional `extend <E impl I> Wrap<E> impl J` is constrained `requires I_c<E>`, matches only conforming arguments, and leaves every other `Wrap<X>` to the primary. Every concrete row the partial covers (`ConformanceRow::covered_by`) uses it in place of a full specialization of its own. A structural generic conformance (a plain `extend <T> Pair<T>` meeting I) is a full specialization per concrete conformer a Kairo instance reaches.

A specialization forwards each requirement to the decl its row names, which may be an own member: one requirement the primary cannot serve makes the whole `(X, I)` a specialization. A generic extension member is called with the extension's arguments as the row bound them, then the requirement's own, never deduced. In a partial specialization a generic member call through the dependent receiver carries the `template` keyword.

A pointer conformer's specialization names Self through a member alias, `using __kairo_Self = T *;`, so `const Self` stays the pointer made const rather than a pointer to const.

A conformer met structurally keeps its own result type. When that differs from a panicking requirement's result (a smaller panic set, or no panic), the member converts it, `::__kairo_pcall<R>([&] noexcept { return ...; })`, as a widened `fn` value does ([Panic.md](Panic.md#codegen)).

Members are defined inside the class: they have no Kairo body to put out of line and are a pure function of the row, which is the synthesized-member exception to [invariant 25](Pipeline.md#invariants). In-class means inline, so the text may appear in every TU, and nothing is homed or explicitly instantiated for a witness.

### When a row needs a specialization

EmitWitness decides per row, from spellings, never by lookup (`EmitWitness::needs_specialization`). The primary serves a row exactly when every requirement's decl is a member function of a Kairo record conformer (own or inherited, static for a static requirement) whose C++ signature, through CXXSpell, equals the witness member's forwarded-to signature. Otherwise the row is a specialization. In practice that is:

- any requirement met by an extension member (plain `extend X` or `extend X impl I`);
- every conformance of a builtin (`i32`, `bool`), which has no members; the conformer is spelled by `CXXSpell::_type`;
- any requirement met by an imported C++ member, whose C++ type is not Kairo's to compare;
- every row of an interface that declares an associated type.

A row of an interface with only constructor requirements has nothing to forward, and the primary serves it, builtin conformers included.

A requirement may be its own witness (`ConformanceChecking:: _native_implementation`): an `op ==(const self, [const] other: Self) -> bool` on a builtin, a pointer or an imported C++ record with no matching member, met by the type's own `==` (the member is `return (self == other);`, C++ choosing a member or free operator); and the Hash lang item's `hash` on a pointer (`reinterpret_cast` of the address; HashMap mixes every hash, so identity suffices) or on an imported C++ type with no `hash` member (`std::hash<X>{}(*self)`). Any other requirement as its own witness is an ICE.

Explicit (`impl`) and structural conformance decide nothing here; the implementing decls do. They differ in when the row exists (see [Emission](#emission)).

### The concept

Every emitted generic declaration with interface bounds carries `requires ::N::I_c<P, A...> && ...` in its template head, one conjunct per `P impl I<A...>` in bound order, spelled by `CXXSpell::template_head` so the declaration and the body carry the same clause. An `extern template` line or explicit instantiation definition has no template head and carries none; clang matches it to the constrained template. Two declarations of one function template must have equivalent heads ([temp.over.link]) and clang mangles the constraint into the symbol, so a mismatch is a link failure, and adding or removing a bound changes a generic's C++ ABI. `derives`, kind bounds, value predicates and `where` are not rendered: Kairo checks them at the instantiation site and WhereDispatchLowering reduces them ([Lowering.md](Lowering.md#passes)). A bounded pack's head is a fold, `requires ((I_c<T> && ...))`.

The concept is

    I_c<S, A...> = requires { typename I_witness<S, A...>::Node; ... }
                && requires (<one parameter per requirement argument>) {
                       <a call of each witness member>; <each constructor requirement>; }

or `true` when the interface requires nothing. It does not conjoin base interfaces' concepts: a composed interface's requirement list already holds everything it derives. For an instance Kairo enumerated the concept is always true (ConformanceChecking proved the row), so in a Kairo TU it fails only on a compiler bug, and then as a constraint failure at the call. Its purpose is the instantiations Kairo cannot enumerate: a C++ host's, and clang's own ([Codegen.md](Codegen.md#templates)). Generic requirements and generic associated types are left out (there is no argument to probe them with), as are bounds on the interface's own parameters. [Invariant 13](Pipeline.md#invariants) states the rule: emitted templates carry no `requires` except these concepts, one conjunct per interface bound, and a record's self-contained value predicates.

A generic record primary is the exception (`CXXSpell::defers_bounds`): its head carries none of its own interface bounds. Clang checks a class template's constraints where the template-id is named, and a class names an instance over itself while still incomplete (the CRTP base `class Seven : Mixin<Seven>`, a field `*Holder<Node>` inside `Node`), where no concept can hold yet. The bound is pinned instead after the home's explicit instantiation, `static_assert(::ns::I_c<A...>, ...)` per bound (`CXXSpell::bound_asserts`, `InterfaceEmitter::_instantiation`). A record's mangled names carry no constraint, so the ABI is unaffected. A partial specialization keeps its clause (there it selects), and a member template its own. The cost: a C++ host naming the record at a non-conforming argument fails inside a member that calls the witness, not at the name.

A generic record's value predicate that names an eval fn or eval constant (`class <eval N: i32> Ring requires is_pow2(N)`) cannot go on the head, which is also the tier-0 forward declaration's, written before the items are declared. It becomes `static_assert(<predicate>, "requires clause of 'Ring' not satisfied")` at the top of the record body (`CXXSpell::body_predicates`, `InterfaceEmitter::_record_def`), checked per instance; the items it names are the record's early items (`EmitPlan::_decl_type_items`, [Codegen.md](Codegen.md#templates)). A partial specialization is exempt, since its clause selects. An ADT enum's predicates take the same form on its layout record (`_adt_def`). A generic plain enum is an `enum class`, which C++ cannot template.

### Interfaces, case by case

- Composition. Every interface is normalized into a plain requirement list before binding (`Compiler/Sema/Check/InterfaceComposition.k`). A witness belongs to the bound: a call bound to `Readable::read` through `T impl Stream` is `Stream_witness<T>::read`, and Stream's one row covers its whole list. A requirement inherited through a concrete generic instance (`derives Container<i32>`) is spelled at that instance's arguments. One inherited through a dependent instance (`interface <T> F derives Container<T>`) is two substitutions deep: the primary and concept apply only the first (they are written inside F's template, where T is in scope), and a specialization spells it through the source Sema substituted at the row's arguments (`ConformanceRow::sources`), which is both at once (`EmitWitness::members_with`).
- Multiple bounds. Each call is bound to one requirement and goes through the bound whose list contains it. Two bounds declaring the same `m` is the typer's ambiguity, never codegen's.
- Default methods do not exist ([interfaces](README.md#language-reference)), so there is no default-body forwarder.
- A call through a pointer to a virtual interface is runtime dispatch through a different table. Not implemented.

### Associated types

`T::Node` in a bounded body is the bound's witness member type, `typename ::N::I_witness<T>::Node` (`CXXSpell::assoc_spelling`), so one template body serves every instance and C++ picks the type per instance. Every row of an interface that declares an associated type is a specialization opening with `using Node = <ConformanceRow::assoc_types[i]>;` (the conformer's alias, or the default an explicit conformance took); members after it name `Node` bare. The primary declares no associated type and omits every member whose signature names one, and the concept opens with `typename I_witness<Self>::Node;`, so a type with no specialization fails the concept instead of hard-erroring inside the primary, as `using Node = typename Self::Node;` in the primary would on any concept check of a non-conformer.

`T::Node{}` and `T::Node(args)` are value-initialization and construction of that member type. A generic associated type is a member alias template, `template <class K> using Map = Bag<K>;`, its parameters those of the supplying alias, spelled `typename I_witness<T>::template Map<int>`. One reached through another associated type (`T::Item::Inner`) goes through the bound of the base that requires it (`AssocType::bounds`): `typename Holder_witness<typename Store_witness<T>::Item>::Inner`, and the row's `assoc_rows` (proofs that the supplied types meet their bounds) are admitted with it. The parts of associated types still rejected with SC116E are.

## Call sites

The receiver's form is a lowering's decision. ExtensionLowering owns the table: the address of an addressable receiver, `__kairo_tmp` for a prvalue, the pointer as is, the object for an operator ([MemberLookup.md](MemberLookup.md#extensions), [Lowering.md](Lowering.md#passes)). A call whose callee is a requirement (its `semantic_dc` owner is an `InterfaceDecl`) is rewritten there into a plain call, receiver first, exactly as an extension member's is, and records its witness: `CallExpr::witness_iface` (the declaring interface instance, with its arguments as seen through the bound and any `derives` edge) and `witness_self` (the receiver's canonical, a dependent `T`).

- A static requirement through `T::make(x)` takes no receiver; its Self is the qualifier. A type parameter used as an expression denotes its type (ExprTyper), which is how `T::` reaches the bound and `-> Self` reads back as T.
- An operator on a bounded `T` binds to the bound's requirement (OperatorTyping gathers candidates from the bounds alone), so OperatorLowering mints the call and the same arm takes it. An operator the bounds do not declare stays deferred.
- A generic requirement's own arguments are `CallExpr::instance`'s.
- The same static requirement used as a value (`var f: fn(usize) -> usize = A::alloc`) has no call to carry the witness; ExtensionLowering records it on the `::` step (`ChainExpr::Step::witness_iface` / `witness_self`), and EmitIR names the witness's static member, a plain function.
- The qualified form `I::m(x)` takes Self from the first argument's type; on a concrete conformer the call carries its own row (`CallExpr::witness_row`). A generic interface's qualified form (`Container<i32>::get(x, 0)`) keeps the qualifier on `witness_iface`; overload resolution binds the interface parameters from it, and on a bounded parameter ConformanceChecking picks the bound the qualifier names (SC001E when none does). A bare qualified call to a generic interface's requirement (`Container::get(c, 0)`) is SC001E asking for the arguments.
- `T::m(a)` for a method is R027E; the method form is `.`.

EmitIR's `_call` has one arm for these, ahead of the qualifier arm: the callee is spelled `::N::I_witness<Self, A...>::[template ]leaf(`, with `template` whenever the member is generic (the witness is a dependent type), and the arguments follow as an unbound call's do, `self` included, each compared and cast against the requirement's parameter with Self replaced by the witness's Self.

| Kairo | C++ |
|---|---|
| `a.scale(2)` | `::ring::Scalable_witness<T>::scale(&a, 2)` |
| `p->scale(2)` | `::ring::Scalable_witness<T>::scale(p, 2)` |
| `make().scale(2)` | `::ring::Scalable_witness<T>::scale(::__kairo_tmp(make()), 2)` |
| `a == b` | `::m::Eq_witness<T>::__kairo_op_eq(a, b)` |
| `T::make()` | `::m::Eq_witness<T>::make()` |
| `s.push<U>(u)` | `::m::Sink_witness<T>::template push<U>(&s, u)` |
| `c.get(0)` with `T impl Container<U>` | `::m::Container_witness<T, U>::get(&c, 0)` |

Non-generic code never reaches a witness: a call on a concrete receiver is bound to the implementing decl and is spelled as any qualified call. A body with no interface to key a witness on never uses one (the compiler-build internal regime, [BuildSystem.md](BuildSystem.md#internal-generics-regime)).

## Emission

Witness pieces are plan entries beside the extension scopes. Every definition is emitted inside the interface's namespace wrapper (a specialization is declared in the primary's namespace; for a pathless TU's priv interface that is the unnamed namespace, reachable only from that TU).

| Piece | Key | Tier | Admitted by |
|---|---|---|---|
| Primary forward declaration `template <class __kairo_Self, ...> struct I_witness;` | `InterfaceDecl` | 0 | as the primary |
| Concept | `InterfaceDecl` | 0, ahead of every head that names it, bounded records' forward declarations included | as the primary |
| Primary definition | `InterfaceDecl` | 1, after the Complete deps of its signatures | a requirement use; every generic decl the plan declares with a bound on I (the concept is in its head, so a tier-2 declaration needs it); every specialization of I; in Header and Include modes every pub interface root |
| Specialization | the row | 1, after the primary, the conformer, every extension scope it forwards to, and its signatures' deps | every TU whose plan holds an instance binding the row (see below); for declared rows, every TU and header that emits the declaring decl |
| `std::hash<K>` adapter | the row | 0 (class, inside `namespace std`), 1 (operator) | an imported C++ container keyed by a Kairo `K impl Hash` |

The concept names only the declared witness, and its requires-parameters need their types declared, not complete, so it sits in tier 0. A primary or specialization is an inline definition, so the by-value records in its signatures are Complete deps, as for an operator forwarder.

The conformer of every concrete row an instance binds is admitted at Complete whether or not the row needs a specialization: the primary's members are `requires`-guarded on `&X::m`, which an incomplete `X` fails, so a TU naming `X` only as a generic argument would see the concept false.

### Which TUs write a specialization

A specialization is admitted in every TU whose plan holds an instance binding its row: a tier-3 entry (home or `extern template`), or an instance reached by a visible body, closed over the instances that instance's body reaches ([Generics.md](Generics.md#instantiation-registry)). Admitting it in the home TU alone would be wrong: visible template bodies are emitted C++ `inline`, an explicit instantiation declaration does not suppress implicit instantiation of an inline function, so any TU that calls `twice<Metric>` may compile it, and one that does so without the specialization in sight compiles the primary instead (ill-formed NDR). The `extern template` line itself checks `Scalable_c<Metric>`.

A declared row (`class X impl I`, `extend X impl I`, concrete X and I) is built by ConformanceChecking at the declaration and recorded under the declaring decl (`declare_row`). EmitPlan also admits it in every TU and header that emits that decl: there `X` is complete and `I` named, and `X`'s header is where a C++ host looks, since a host instantiates Kairo templates with types Kairo never paired. A declared conformance that does not hold is not recorded, and the host then fails at the concept.

A structural row met by extension members reaches only the TUs that hold a Kairo instance needing it. A C++ host instantiating with that type fails `I_c` at its call; it never compiles a different witness.

### Rows, instances and ODR

Witnesses add no registry entry and no tier-3 line: the members are inline, the primary is instantiated implicitly per Self wherever a body uses it, and a specialization is complete on its own. The registry's instance to rows map (`InstanceEntry::rows`, written by ConformanceChecking with `add_rows`) is the whole input of the specialization edge. The map is program-wide: an instance's rows are the union over every TU that checked it, in first-found order, so every TU holding the instance emits the same specializations in the same order whatever it imports. Which rows a TU's Sema may use is a per-TU filter that codegen never applies.

A generic requirement called with arguments registers a CallExpr instance whose primary is the requirement. It names no C++ function, and EmitPlan never writes a tier-3 line for it (the guard is the `InterfaceDecl` owner check at admission). A generic record with a bound (`class <T impl I> Box`) and a bounded generic extension are ordinary instances: `Box<Metric>` in a plan admits the rows its bounds bind, and the witness is named inside the class template's member bodies.

The plan keeps one entry per interface and per row. A specialization is written completely, every requirement whatever use touched it, as an extension scope is, so its text is a function of the interface and the row alone and every TU and header that writes it writes the same class. `IncludedDecls` keys pieces by the same identity, so a second `#include "foo.k"` in one C++ TU drops what an earlier one wrote; a header guards each definition with `__KAIRO_W_<key>`. Rows are keyed with `usize` / `isize` folded into their fixed-width types where the target makes them one C++ type (`CXXSpell::fold_sizes`): the first row emitted is the one class.

Two decls declaring the same generic conformance (`class <T> Box impl I` beside `extend <T> Box<T> impl I`) produce two partials keyed by different parameter names, which clang reports as a redefinition, with the related host-side gaps.

### The std::hash adapter

An imported C++ container keyed by a Kairo record (`cxx::std:: unordered_map<string, V>`) defaults its hasher to `std::hash<K>`, whose primary is disabled for any type C++ was not told about. For each `K impl Hash` such a container instantiates, EmitPlan (`_std_hash`) adds a `WitnessPiece` with `std_hash` set. Tier 0 declares `template <> struct hash<K>` in `namespace std` with its call operator declared only, so it precedes every record whose field instantiates the hasher. Tier 1 defines the operator, forwarding to `Hash_witness<K>::hash`, after the row's specialization when it has one. Equality needs no adapter: libc++'s `std::equal_to<K>` is `a == b`, and Hash's `op ==` is a member.

### Header and include modes

Header mode emits the witnesses its roots and bodies reach, as a preamble does; the primary and declared specializations are part of a module's C++ interface. Include mode (`#include "foo.k"`) is a Header's roots emitted as a Preamble is and adds no rule ([Codegen.md](Codegen.md#pipeline)).

### Errors

User errors are Sema's: an instantiation whose argument does not conform (SC001E at the call, with notes at the bound and the requirement), a conformance whose implementing decls are outside the instantiating TU's import set, an unparameterized bound on a generic interface. Codegen keeps ICEs, each naming its owner:

| ICE | Owner |
|---|---|
| a requirement callee with no recorded witness, or reached as a `::` / member step | ExtensionLowering |
| a row with no decl for some requirement, no type for an associated type, or no source for an inherited requirement | ConformanceChecking |
| a generic extension member as a witness with no extension arguments on its row | ConformanceChecking |
| a requirement as its own witness other than `op ==` / Hash's `hash` | ConformanceChecking |
| an interface with a value parameter | not built |

### Tests

`Tests/Codegen/witness/`: each file a `--print-cxx` golden plus, where it links, a run whose exit code is computed. Single-file tests cover extension and own-member conformers (`extension.k`, `own_member.k`, `inherited.k`, `builtin.k`, `native_eq.k`), operators (`operator.k`, `bound_ops.k`, `compound.k`, `generic_operator.k`, `op_as_two_requirements.k`), static and constructor requirements (`static.k`, `static_decltype_return.k`, `ctor_requirement.k`, `ctor_lifecycle.k`), generic interfaces and conformances (`generic_iface.k`, `generic_extension.k`, `generic_requirement.k`, `generic_record.k`, `qualified.k`, `qualified_generic.k`), composition (`derives.k`, `composed*.k`), reached instances (`nested.k`, `deep_chain.k`, `bound_call_*.k`), receivers (`receivers.k`), and associated types (`associated_type.k`, `assoc_*.k`). Multi-module fixtures: `diamond/` (two instantiating TUs, `clang++ -Wodr` link, the constrained symbol identical in both objects), `header/` and `header_declared/` (a C++ host through `--emit-headers`), `nested_modules/`, `assoc_modules/`, `assoc_path_modules/`, `visibility/`, `operator_ext/`, `lone_literal/`. `declared_twice.k` is XFAIL until generic declared rows are keyed up to alpha-equivalence ([Interfaces.md](Interfaces.md#conformance)). The Sema error for a non-conforming argument is `Tests/Sema/Check/conformance_at_instantiation.k`.

### Open questions

These are undecided design points with no implementation behind them.

1. Reserved names. `Scalable_witness` / `Scalable_c` can also be declared by a user in the same namespace; CxxNameCheck reserves only the `__kairo_` prefix. Either rename to `__kairo_witness_<I>` / `__kairo_concept_<I>`, or have CxxNameCheck reject the suffixed forms.
2. Structural conformance through extension members cannot reach a C++ host that instantiates on its own. Whether a host needing `impl` is the rule, or such rows should be rejected or enumerated, is open.
3. Two Kairo builtins, one C++ type. `fold_sizes` merges `usize`/`u64` and `isize`/`i64` rows where the target makes them one type. Sema does not reject such a pair: the library's `u64` and `usize` `Hash` witnesses behave identically, so the first row winning is harmless. A pair that forwards to diverging decls would need a rule.
4. Overlapping conformances (`extend <T> Vec<T> impl I` beside `extend Vec<i32> impl I`): if allowed, the registry's partial selection must agree with C++ partial ordering.
5. Free functions (C++ or ADL-found Kairo) as witnesses: if allowed, such a row is a specialization forwarding to the function, qualified.
6. What `I_c` checks: generic requirements, bounds on the interface's own parameters and generic associated types are excluded.
