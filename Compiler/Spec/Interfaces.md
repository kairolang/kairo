# Interfaces

How the compiler normalizes interfaces, decides conformance and resolves associated types. The language rules are in the language reference (`interfaces.mdx`, `interfaces-requirements.mdx`). The C++ shape of a conformance (witness specializations, concepts) and the spelling of calls through a bound are in [Witnesses.md](Witnesses.md); generic instances and their checking are in [Generics.md](Generics.md).

## Conformance

`ConformanceChecking` (`Compiler/Sema/Check/ConformanceChecking.k`, CHECK phase, after ExprTyper) decides conformance wherever a generic's `P impl I` bound meets a concrete argument, and fills the conformance table.

### Rows

`conforms(X, I)` finds the row for conformer `X` and interface instance `I`: for each requirement in `I`'s composed list ([Interface algebra](#interface-algebra)), the declaration on `X` that implements it. A candidate is anything member lookup on `X` finds: an own or inherited member, an extension member, an imported C++ member. Special requirements:

| Requirement | Met by |
|---|---|
| constructor (`decl_is_ctor_requirement`) | an own constructor of `X` (its own table under `DeclName::ctor()`, never a base's) matched on the non-`self` parameters; a zero-parameter one on a record declaring none by the implicit `X()` (the record decl stands as witness); a builtin meets none (`i32()` is SC037E) (`_ctor_implementation`) |
| lifecycle (`@copy fn Copyable(self, const other: Self)`, `@move`) | category ([Ownership.md](Ownership.md#copy-and-move)): `@copy` by COPY, `@move` by COPY or MOVE, builtins included |
| native (`_native_implementation`) | the requirement itself, when no member matches: an operator requirement a builtin or a pointer has built in with the requirement's shape (`_builtin_op_result`, see [Builtin operators as witnesses](#builtin-operators-as-witnesses)), or `op ==(const self, other: Self) -> bool` on an imported C++ record; the Hash lang item's `hash` on a pointer or an imported C++ type (`std::hash<X>`) |

The match is exact on canonicals after `Self` is replaced by `X` (`Substitution::replace_self`) and the interface's parameters by the bound's arguments: the same receiver constness, parameter count, modes and types, and return type. Requirement generic parameters are matched by position (`fn <U> put(u: U)` and `fn <V> put(v: V)` are one signature). A generic record's own member is matched at the instance's arguments. Exactness is required because a witness forwards to the decl the row names and must reach the same one in every TU.

`ConformanceRow` (`Compiler/AST/Context/InstantiationRegistry.k`) lives in the build-wide registry, keyed on canonical `(conformer, interface)`:

| Field | Meaning |
|---|---|
| `conformer`, `iface`, `iface_decl` | canonical unqualified conformer; canonical interface instance; its `InterfaceDecl` |
| `declared` | the `impl` that declared it (`class X impl I`, `extend X impl I`), or null for a structural row found at a use |
| `witnesses`, `reqs` | parallel: implementing decl and the requirement it implements |
| `ext_args`, `ext_arg_count` | a generic extension member's arguments as the conformer binds them (`extend <E> Wrap<E>` met by `Wrap<i32>`: `E := i32`) |
| `sources` | the interface instance each requirement came through, at this row's arguments (`interface <T> F derives Container<T>` met as `F<i32>`: `Container<i32>`) |
| `assoc_types`, `assoc_rows` | [associated types](#associated-types) supplied, and the rows proving they meet their bounds |
| `covered_by` | the generic declared row that covers this concrete one; EmitPlan admits that row's partial specialization instead of a full one |
| `ok` | every requirement found |
| `seen_by` | the TUs the row is usable in |
| `hidden`, `clash` | detached rows only (below) |

A declared row is recorded under its declaring decl (`declare_row`) for EmitPlan, which admits it where that decl is emitted. A generic declared conformance is one row over the declaring decl's own parameters (`extend <T> Pair<T> impl Container<T>`: conformer `Pair<T>`, interface `Container<T>`).

Rows are keyed on the interface's arguments, so `impl VectorI<i32>` and `impl VectorI<string>` on one type coexist. An interface bound must name every interface argument (`T impl VectorI<U>`); an unparameterized bound on a generic interface is an error. The type checker binds a call through a bound to the requirement decl, which is what the witness is keyed on; non-generic code never touches a witness. How overlapping generic conformances for one key should resolve is an open design question; today a second row for one key is an error at its use.

Rows on an instance (`InstanceEntry::rows`) are the rows of its primary's `impl` bounds in bound order, then each bound interface's `derives` closure (`_push_closure`). A `derives` bound is checked with `Substitution::derives_from` (SC156E).

### Program-wide rows, per-TU visibility

Codegen needs every row of `X<A> impl I` identical in every TU (ODR), so an instance's rows are the union of what every TU that checked it found (`add_rows`), in first-found order: TU (DAG) order, bound order, then each interface's closure. Because a row is one per `(conformer, iface)` key build-wide, in practice the union equals the first TU's list.

Which rows a TU's own Sema may use is a filter. A row is usable in a TU when its extension members are in the TU's transitive import set (`_usable`, `_sees`): the TU's fid, the builtin subtree, and every fid its import edges reach, built lazily per ConformanceChecking. Only extension members are tested: an own member is visible wherever its type is. `seen_by` records the TUs that found the row usable, the declaring TU first.

`conforms()` is the one chokepoint. A table hit is returned only if usable here. Otherwise the requirement match runs again with invisible extension candidates skipped, and its result is detached (`row_detached`, never recorded):

| Detached result | Diagnostic |
|---|---|
| `hidden`: a matching member this TU cannot see | SC162E "implemented by an extension this file does not import", note at the member; no fix-it, since Sema cannot spell the module path |
| `clash`: this TU sees a different implementation than the table's row | SC163E "conforms ... through a different implementation here than elsewhere in the program", notes at both |

A row that does not hold is not recorded at all: it is one TU's view, and the extension index's order dependence could otherwise hand a later TU that does see the member another TU's failure. Member lookup itself is still unfiltered and DAG-order dependent.

A direct use of an instance another TU made live is re-checked once per TU against this TU's view (`_recheck`), reported at this use with no chain, its rows unioned in. It is skipped when the instance already failed (`InstanceEntry::failed`). A reached instance is not re-checked: its rows are implied by its root's bounds, which the root's use checks here.

### Conformance diagnostics

| Code | Condition |
|---|---|
| SC153E | a member's `requires` clause does not hold at the call |
| SC154E | an associated type's default does not meet its own bound (checked at the interface, `_check_assoc_defaults`) |
| SC155E | a qualified requirement call names an interface no bound on the argument provides |
| SC156E | a `derives` bound's argument does not derive the base |
| SC161E | associated-type conformance: supplied type misses its bounds, two different inherited defaults, generic arity mismatch, no associated type declared |
| SC162E | a witness hidden by visibility, or not public with no `impl` in its file |
| SC163E | two implementations of one conformance |

An unmet bound is reported at the instance's use with its instantiation chain ([Generics.md](Generics.md#monomorphization-sync-point)).

Not implemented: the impl-only rule and the orphan rule (no pass exists); a declared `impl` that does not hold is not reported at the declaration; a generic extension member's bounds are not checked at the call; `T(args)` arguments are not checked against the constructor requirement; one generic conformance declared twice is a C++ redefinition (`Tests/Codegen/witness/declared_twice.k` XFAIL; needs alpha-equivalent keying of generic declared rows). Virtual interfaces (`*I`) are not compiled.

Once an orphan rule holds, an `extend X impl I` lives in `X`'s or `I`'s file, which every TU naming both imports transitively, so the visibility filter can then fire only on an orphan. The fixtures in `Tests/Codegen/witness/visibility/` are orphans on purpose.

## Interface algebra

`interface F derives X + (Y - Z) & W` composes requirement sets. `InterfaceComposition` (`Compiler/Sema/Check/InterfaceComposition.k`) normalizes every interface into a plain requirement list before binding and conformance see it; nothing downstream knows an interface was composed.

### Syntax

| Form | Meaning |
|---|---|
| `derives <expr>` | the only form; `derives A, B` is sugar for `A + B` |
| `+` | union (predicate AND: both sets required) |
| `-` | difference |
| `&` | intersection (only shared requirements) |
| `( )` | grouping |

`&` binds tighter than `+` and `-`, which are left-associative. There is no `|` (it would read as "either"), no `^`, and no complement (a requirement set has no universe). `interface F impl X` is S087E with a fix-it replacing `impl` by `derives`. Removing a single member (`X - fn goo`) is S086E: requirements come and go by whole interface.

`DeclParse::_parse_derives_expr` reads the clause by precedence climbing over `+ - &` and parentheses, leaves parsed by the type parser. It stores it in `InterfaceDecl::derives_expr` as `BinaryOperatorExpr` nodes over `ConstraintExpr(Self derives <type>)` leaves, the nodes requires clauses already use, and records `derives_end` (the inlay-hint anchor). `derives_list` keeps the leaves as written; it is metadata, not the lookup path.

### The pass

Slot: T stage, after TypeResolution and RedeclMerge, before ConstraintExtraction and ChainBinding (a bound `T impl F` gets its members at binding). An operand interface is composed first (`compose_state`); a cycle is SC164E. Imported interfaces are already composed, since Sema runs in import DAG order.

The result is `InterfaceDecl::requirements`, one `Requirement` per element, own members included: every interface gets one, so `derives A, B` and `derives A + B` dedupe the same way. Symbol tables are frozen at parse exit, so members are not copied; each entry is the original decl.

| `Requirement` field | Meaning |
|---|---|
| `decl` | the original `FunctionDecl` or associated `TypeAliasDecl` |
| `source` | the canonical interface instance it came through (`Y<i32>`) |
| `leaf` | `derives_list` index (provenance); `u32(-1)` for an own member |
| `bounds` | an associated type's bounds after merging, as a requires-style `&&` |
| `default_ty` | an associated type's kept default |

Element identity (`_same`): a method requirement is its name, receiver (none, `self`, `const self`), its own generic parameters with their bounds, and its parameter modes and canonical types, each source's `Self` normalized to the composed interface's and its parameters bound by the leaf's arguments. The return type is not part of identity. Bounds compare as the set of `impl` / `derives` conjuncts per own parameter; a requirement carrying a value predicate is identical only to itself. So `A::process<T>(val: T)` and `B::process<T impl Serializable>(val: T)` are two elements, and `A - B` keeps `A.process`.

| Operation | Methods | Associated types (by name) |
|---|---|---|
| `+` | same identity is one element; same identity with different return types is SC167E | one element with the union of both bounds; one default kept; two different defaults SC168E |
| `-` | removed on identity alone, whatever the return type | removed whatever its bounds |
| `&` | kept on identity alone | kept with the bounds both state, a default only if both give the same |

Other errors: a leaf that is not an interface (SC166E); a kept method naming `Self::N` for an associated type the composition removed (SC169E); an interface whose list is empty, a written `interface Marker {}` included (SC165E). An empty interface constrains nothing because conformance is structural, and `extend X impl Dummy` would reopen any type. An operand's `requires` clause is not carried into the composition.

Is-a follows from structure: a type meeting `F` meets `X` wherever `X`'s requirements are all in `F`'s list; `-` and `&` imply no nominal edge. Consumers read `requirements`: member lookup on an interface, conformance (`_reqs`, per entry's source instance), ExtensionLowering's choice of the bound whose list contains the callee, and EmitWitness (members, concept and dependencies; no concept conjoins another). A call to an inherited requirement goes through the bound's interface, not the declaring one's ([Witnesses.md](Witnesses.md#call-sites)).

`InterfaceComposition::derived_text(F)` spells the derived part of `F`'s body as Kairo source (requirements as declared in their source, `Self` as `Self`, the source's arguments substituted, associated types with merged bounds and default; own members omitted). It is the text an LSP inlay hint shows after the derives clause; `--print-sema` prints it per composed interface (`SemaDump`), so tests pin what an LSP will show.

## Associated types

### Syntax

Inside an interface only. Outside one, a `type` with no `=` is S050E and an `impl` bound on it is S088E.

```text
type N                      // bare
type N impl X               // bound
type N impl X, Y            // several bounds
type N = usize              // default
type N impl X = Default     // bound and default
type <K impl Hashable> M    // generic associated type
```

Each is a `TypeAliasDecl` with `is_associated = true` and `aliased` the default or null. Its bounds are its `requires_clause`, the `&&` conjunction every requires clause desugars to, so ConstraintExtraction partitions them as for any decl. `type N impl X + Y` (an interface expression) is not accepted: it would need an anonymous composed interface.

### Representation

`AssocType` (`Compiler/AST/Node/CanonicalNodes.k`) is the canonical type of `Self::N`, bare `N` inside the interface, and `T::N` on a parameter with interface bounds. It is always dependent and interned by `CanonicalTypeStore::assoc`.

| Field | Meaning |
|---|---|
| `base` | the parameter, or the interface's `Self` record |
| `iface` | the interface instance that declares the requirement (`TypeUtil::assoc_iface` normalizes to it, so `B::Node` through `B impl Big`, `Big derives Graph` is Graph's `Node`) |
| `assoc` | the requirement |
| `args` | a generic associated type's arguments (identity) |
| `bounds`, `bounds_state` | cache of `Substitution::bound_ifaces`: the requirement's `impl` clause read with `Self := base`, the interface's parameters := `iface`'s arguments, its own parameters := `args`; not cached while the clause is unresolved |

Inside a generic interface `Self` is `I<T...>` over its own parameters. Resolution checks the name against the bounds: no bound declaring it is R025E, two are R028E. A generic associated type is named with exactly its arity (`T::Map<K>`).

`Substitution::assoc_type` is the one creator. T builds the type, reading bounds from the owner's requires clause (ConstraintExtraction runs after T, so a bound's right-hand side is resolved on demand); `TypeResolve::_ready_assoc_clause` resolves an associated type's own clause in its declaration scope before a member is formed through it. Paths of any depth (`H::A::B`, `Self::Item::...`) are walked head by head in type position (`TypeResolve::_assoc_through`) and in expressions (`MemberTyping::_assoc_step`, ChainBinding). A `derives`-bounded `T` keeps the old deferral.

### What it is for a type

`Substitution::assoc_witness` answers what `N` is for `X`: `X`'s alias of that name (member, inherited, or extension, read through `X`'s arguments); else, for an explicit conformance only (`impl` on `X`, an `extend X impl`, or one of an interface deriving it), the default with `Self := X`. `replace_self` and `substitute` route `AssocType` through it, so the conformance match, a call result through a bound and the instance fact (`T::Node := S` at a call) are one computation.

Conformance: a structural conformer must declare every associated type, and the supplied type must meet the associated type's own bounds; the row records the supplied type in `assoc_types` (the witness is the alias decl, or the requirement itself for a default) and the proving rows in `assoc_rows`, which EmitPlan admits with the row. An associated type inherited from a generic interface is declared at the instance the bound reaches it through (`TypeResolve::_declaring_through`). A derived interface may default an inherited one (`interface D derives G { type Node = i64 }`): InterfaceComposition merges it as `G`'s requirement default, and `assoc_witness` takes it from the interface a conformer declares (`_derived_default`, `_read_derived_default` for a derived generic interface). Two different defaults from declared interfaces for one inherited requirement: neither applies, and unless the conformer declares the type itself conformance fails (SC161E naming both). A default must meet its own bounds, checked once at the interface (SC154E); inside the interface it is never expanded. A generic associated type is supplied by a generic alias of the same arity; its parameter bounds are checked at a written use with concrete arguments (`ConformanceChecking::_check_assoc_args`).

A body uses an associated-type value only through its bounds: `TypeUtil::checked_head` makes operators, conversions, formatting, null tests and patterns on it follow the rules for a checked parameter ([Generics.md](Generics.md#instantiation-model)). Construction (`T::Node{}`, `T::Node(args)`) needs a constructor requirement of that arity in the associated type's bounds (`Substitution::bounds_construct`; SC251E otherwise); a field list is always rejected. Members of an associated-type value are exactly those its own bounds declare (`x.show()` with `type Node impl Display`), at any depth (`T::Item::Inner`, `T::Item::make()`).

C++ spelling: `T::Node` is `typename I_witness<T>::Node` through the bound that declares it (`CXXSpell::assoc_spelling`, `_assoc_bound_of`). Every row of an interface with an associated type is a specialization opening with `using Node = <type>;`; the primary declares none, and the concept probes it with `typename I_witness<Self>::Node;`. A `using Node = typename Self::Node;` in the primary was rejected: instantiating the primary (any concept check, for example of another overload candidate, or a kcc host's type) would hard-error on a type without `Node` instead of failing the concept. So a C++ host type conforms to an interface with associated types only through a Kairo `impl`. Details in [Witnesses.md](Witnesses.md#the-c-shape).

Not implemented: a non-generic ADT nested in a generic class is SC116E (EnumLayoutLowering keys its generic regime on the enum's own parameters). `var x: T::Node` with no initializer is not checked for a constructor bound.

## Builtin operators as witnesses

An extension cannot declare an operator on a builtin type, so a builtin meets an operator requirement through the operator it has built in. The requirement must be a method with no generic parameters, `const self` (a compound assignment: `self`), its operands all `Self`, and its result the builtin's result with `Self` substituted: `void` for a compound assignment, `bool` for a comparison, `Ordering` for `<=>`, `Self` otherwise. `ConformanceChecking::_builtin_op_result` is the table:

| Operator | Built in on |
|---|---|
| `==` `!=` | integers, floats, `bool`, `char`, the C character types, `byte`, pointers |
| `<` `<=` `>` `>=` | integers, floats, `char`, the C character types, pointers |
| `<=>` | integers, `bool`, `char` |
| `+` `-` `*` `/` | integers, floats |
| `%` `<<` `>>`, unary `~` | integers |
| `&` `\|` `^` | integers, `bool` |
| unary `-` | signed integers, floats |
| unary `+` | integers, floats |
| `op=` (compound) | wherever its binary operator gives back `Self` |

Not granted: a float's `%` and `<=>`, `^^`, `byte` beyond `==` / `!=`, `++` / `--`, and every operator but `==` / `!=` on a float the library implements as a class (`f8e4m3`, `f8e5m2`, `f256`, `f512`). `!` cannot be a requirement (S045E: not overloadable). A requirement that is not on the table fails with SC162E, as a missing member does. The non-operator requirements of the same interface still need a member or an extension member. An imported C++ record keeps only the `==` grant; its other operators are its members, met by the primary witness.

