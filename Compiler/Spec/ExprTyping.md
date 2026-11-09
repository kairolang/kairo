# Expression typing

The expression typer (pass X, `Compiler/Sema/Type/`) gives every expression in a TU its type, value category and flags, resolves every call and user operator to one declaration, and checks every implicit conversion. Its place in the Sema schedule is in [Pipeline.md](Pipeline.md#sema-pass-order); the invariants it must keep (what X may write) are in [Pipeline.md](Pipeline.md#invariants).

Overload resolution, inference and checking are one demand-driven system: choosing an overload needs the argument types, typing the call needs the overload, and a type mismatch is what remains when no conversion exists.

## Expression typing

### Components

`ExprTyper` derives the RecursiveASTVisitor and one mixin per concern, in the shape of the parser. Mechanisms with no traversal of their own are components held by value.

| File | Kind | Owns |
|---|---|---|
| `ExprTyper.k` | driver | the memo, `type_of(e, expected)`, side tables, value checks |
| `TypeUtil.k` | component | read-only type and declaration queries, type rendering |
| `Conversion.k` | component | the implicit conversion relation ([Conversions](#conversions)) |
| `OverloadResolution.k` | component | candidates and arguments to one declaration ([Overload resolution](#overload-resolution)) |
| `ArgumentDeduction.k` | component | unification, `member_through`, `replace_self`, receiver seeding |
| `Substitution.k` | component | bindings and their rewrite, `derives_from`, bounds through a dependent head |
| `LiteralTyping.k` | mixin | scalar and list literals |
| `OperatorTyping.k` | mixin | builtin and user operators |
| `CallTyping.k` | mixin | callee shapes, constructor calls, callee promotion |
| `MemberTyping.k` | mixin | chains, subscripts |
| `CastTyping.k` | mixin | the `as` family |
| `ControlTyping.k` | mixin | `if` / `match` / `try` joins, closures, initializers, lang-item desugars |
| `StmtTyping.k` | mixin | function frames, `return`, inferred declarations, conditions, binders |
| `PatternTyping.k` | mixin | pattern heads, payload fields, binder types |
| `NullnessFlow.k` | component | the nullness analysis and the null-test classifier ([Nullables.md](Nullables.md#passes)) |
| `PanicSets.k` | component | panic set formation ([Panic.md](Panic.md#effect-sets)) |
| `VariadicEnum.k` | component | picking the element of a pack-expanded variant by payload type |

### What X writes

X writes only into slots on existing nodes; it never allocates an AST node.

| Slot | Meaning |
|---|---|
| `Expr::type_`, `value_category`, `expr_flags`, `poisoned` | the expression's type state |
| inferred type of a `VariableDecl`, `ClosureExpr`, expression-bodied `FunctionDecl`, binder | the canonical node itself (self-canonical), so readers of `->canonical` are unchanged |
| `resolved_decl` on a `NamedIdentExpr` or `ChainExpr::Step` callee | promotion of `candidate_cell` to the selected declaration |
| `resolved_op`, `op_via_free` on Binary / Unary / Assign / Subscript / `TypeCastExpr` | the user operator selected |
| `BinaryOperatorExpr::op_rewrite` | a comparison derived from `op ==` (`!(==)`) or `op <=>` (`(<=>) <op> 0`), so OperatorLowering never looks an operator up again |
| `BinaryOperatorExpr::tag_eq` | `==` / `!=` on two values of one ADT enum with no `op ==`: compare tags |
| `op_instance` (Binary / Unary / Assign), `CallExpr::instance` | the registry entry of a generic callee's instance (`*InstanceEntry` as `*void`), from which EmitIR spells template arguments and EmitPlan homes the instance |
| `CallExpr::arg_map`, `pack_len` | argument placement over `f->params` (`self` included): -1 a default, -2 the bound receiver in slot 0 |
| `CallExpr::ctor_decl` | the selected constructor of a constructor call (the callee names the type) |
| `NamedIdentExpr::narrowed_from`, `ChainExpr::Step::narrowed_from` | the `T?` of a read the nullness analysis proved non-null and typed `T` ([Nullables.md](Nullables.md#passes)) |
| `variant_decl` on the construction node, `InitField::field_decl` | an enum variant construction ([Dotted variants](#dotted-variants-and-variant-construction)) |
| `StringLiteralExpr::c_string` | the C string parameter a literal argument binds ([Conversions](#boundary-rungs)) |
| list literal `slice_ctor`, `owner_ctor`, `storage` | [List literals](#list-literals) |
| `TypeCastExpr::resolved_ctor`, `enum_check`, `asserting_downcast` | [Casts](#casts) |
| ranged `for`: `iter_kind`, `iter_elem`, `iter_op`, `iter_inst`, `cxx_*` | read by IterLowering ([Lowering.md](Lowering.md#passes)) |

`Lower/` reads these slots; codegen reads the instance slots and `ctor_decl`.

The narrowed-read mark is the one place, besides the `&` marker, where a memoized `type_` is rewritten after the node was typed. The consumer that needs the value rewrites it (an operator, `.` / `->`, a conversion to `T`, a call taking `T`), never the use itself, so a use that does not read the value keeps `T?`.

### Terminal states

Every expression ends in one of four states:

| State | Representation | Consumers |
|---|---|---|
| typed | `type_` set | everyone |
| poisoned | diagnosed, `type_` null | skip |
| unknown | `IsInstantiationDependent` set, `type_` null, not poisoned | skip checks on it: dependent, foreign, or a hole a later pass owns |
| type- or module-denoting | recorded in the typer's side tables | only a callee or initializer head may read it |

Where a value is required (an initializer, an argument, an operand, a converted or returned value), a type-denoting expression is SC094E "'P' is a type, not a value" (`ExprTyper::reject_type_value`, with a `()` fix-it on a record's name; `typeof x` there is U001E, since TypeInfo does not exist). It is never passed through as unknown to codegen.

An expression is unknown only when its type cannot be named. A dependent type that can be named is a type: in a generic body `Cell<T>{ x: v, n: 0 }` is typed `Cell<T>`. Its fields are looked up on `Cell`'s declaration, each value is typed against the field read through the head's arguments (`member_through`), and the convertibility check is left to the instance when either side is dependent. Unknown is reserved for a head with no record behind it: an unbounded `T::Inner`. Codegen ICEs on an untyped initializer.

The call form is treated the same way: `Box<T>(p)` in a generic body is typed `Box<T>`, an rvalue, and its constructor is chosen by `OverloadResolution::resolve_deferred` ([Overload resolution](#deferred-constructor-calls)). Codegen ICEs on an untyped constructor call.

### Memo and expected type

Types are memoized on the node. `expected` is bidirectional only where a node consumes it: literals, `null`, aggregate / named / anonymous initializers, closures. A node has one parent and so one expected type, which makes the memo sound. Statement overrides call `type_of` with the expected type before the visitor's own pre-order visit, which is then a memo hit.

### Literals

The language rules for literal inference are the language reference's (primitives, "Literal inference"). The compiler side:

- A literal is untyped until assigned. The expected type is tried first and the fit is checked at the literal; with none, an integer defaults to i32, then i64, then i128, then "too large without a suffix". `-lit` folds the sign into the fit.
- A suffixed literal is typed at the literal from the suffix text: `iN` / `uN`, `usize` / `isize` (the target's pointer width), `fN` and `bf16`. A float suffix on an integer body (`5f32`) is that float. Any other suffix is SC074E. The lexer's minimum-width guess is never read as a type.
- Against a parameter, an untyped literal ranks Exact for any type it fits (it takes the type; it is not converted) and is typed with the parameter type after selection. Non-negative builtin integer arithmetic over untyped literals (`ArenaAllocator(256 * 1024)`) ranks as one literal of its folded value (LiteralTyping); a negative intermediate stays unfolded.

### List literals

`LiteralTyping::type_list_literal`. A `[...]` literal takes its type from the target as a scalar literal does: `[T; N]` (the count must match), `[T;]` a Slice, `[T]` a Vector. With no container target it is `[T; N]` over the join of its elements. Empty with no target is an error, as `null` is.

In argument position it is deferred like a scalar literal (`LitKind::List`, element shapes in `ArgInfo::elems`), ranked by shape and typed after selection (`_rank_list`). `[T; N]` with a matching count ranks as its worst element does. Slice and Vector are Converted and unordered against each other, so those two overloads alone are ambiguous (C++ answers span against vector the same way). Deduction against a dependent parameter goes through the element join (`_list_default`) and yields an array, slice or vector by the parameter's shape.

X records three facts and the lowering decides nothing: `slice_ctor` and `owner_ctor`, found by shape through the lang item (parameter count, and whether the single parameter is a Slice), never by name; and `storage`, `FullExpr` or `Extended`. Extended means the literal directly initializes a `var`; it propagates into nested slice literals. A literal SequenceLowering hoists into a `__kairo_ord` local is marked Extended there, since the local is a `var` whose statement-expression block is where the backing array lives.

A slice-typed literal returned, used as the right side of `=`, as a field default, or as an initializer's value for a slice-typed field is a lifetime error (SC001E): those positions have no scope to extend a backing array into.

`[T;] -> [T]` is not implicit because it allocates. `s as [T]` goes through Vector's converting constructor (cast rung 5d records `TypeCastExpr::resolved_ctor`; OperatorLowering rewrites the cast into the construction). A literal takes `[T]` directly.

`[T; N]` is a C array, and X enforces what follows from that: it is not copied (`_reject_array_copy`: an array is initialized only from a list literal), not assigned, not passed by value (write `const`, `@inout`, or take a slice), and not returned (return `[T]` or fill an `@inout` parameter). It may be a local, a field, a literal, a `const` / `@inout` parameter, and what a slice views.

### Dotted variants and variant construction

`ControlTyping::type_named_init`. `.V` and `.V { .. }` take their enum from the expected type, as a `.V` pattern takes it from the scrutinee; a reference, cv and a nullable are looked through. No expected type, one that is not an enum, or an enum with no variant `V` is SC123E; a bare generic parameter is unknown without a diagnostic. In argument position `.V` is deferred like a literal (`LitKind::Variant`, the name in `ArgInfo::lit_name`): Exact against a parameter whose enum has that variant, nothing otherwise, typed after selection. A dependent parameter deduces nothing from it: `f(.A)` against `fn <T> f(x: T)` has no viable candidate.

A variant construction is checked by X and built by VariantInitLowering. X sets `variant_decl` (the pattern enum's own `EnumVariantDecl`) on the node the construction was written as: the `NamedInitializerExpr` of `E::V { .. }` / `.V { .. }` / `.V`, or the `ChainExpr` / `NamedIdentExpr` of a payload-less ADT variant named as a value (`Opt::None`). It sets `InitField::field_decl` on each field to the payload `FieldDecl` it fills. Both are written only once every field matched exactly once. A plain enum's variant gets the slot only when written `.V` (`Dir::North` already is the value). A head (`Shape::Rect` before its braces, a pattern's head) is not a construction (`ExprTyper::variant_head`). `variant_decl_of` is the one reader of the three slots.

### Calls

`CallTyping.k`. Callee shapes:

| Callee | Meaning |
|---|---|
| name | function, overload set, type (constructor call), or fn-pointer value |
| chain | method or set with the chain's receiver, type (constructor call), or fn-pointer value |
| anything else | must be a fn pointer |

Constructors live in the type's own table under `DeclName::ctor()`; no constructor and no arguments is the default constructor. Arguments are typed before resolution, except deferred ones (untyped literals, list literals, `.V`), which are ranked by shape and typed after. A generic callee's instance is registered in the `InstantiationRegistry` ([Generics.md](Generics.md#instantiation-registry)). The return type is the declared canonical; `-> !` is `Never`; an unannotated expression-bodied function's is demanded under a resolution-state cycle guard.

An unqualified call gets ADL over its arguments ([MemberLookup.md](MemberLookup.md#member-lookup)) unless ordinary lookup found a method.

Constructing an abstract class (one with a pure virtual method, a bodyless `virtual fn`, that it and its bases leave unoverridden) is SC249E at the construction with an SC249N note at the method (`CallTyping::reject_abstract`); a pointer to one is fine.

A closure's default parameters belong to the binding, not to its `fn` type: a call through a local initialized with a closure literal takes the literal's defaults for the trailing arguments it omits (`CallTyping::_closure_defaults`), and a `fn` value carries none. Only literal defaults are copied; any other default leaves the call short and the arity error stands.

### Chains

`MemberTyping.k`. Per step:

| Step binds | Type |
|---|---|
| field, variable, parameter | declared type read through the receiver; lvalue |
| variant | the enum |
| method or overload set | callable: no type, legal only as a callee |
| nested type or alias | type-denoting |
| module | nothing |
| `.0` | the tuple element ([Lowering.md](Lowering.md#passes), TupleLowering) |
| operator step | callable via `op_name` |

`?.` peels the nullable and re-wraps. A callable has no type, with two exceptions that are fn pointers: a unique non-method function named as a value, and a generic one named with every type argument written (`pick<i32>`), read over its signature with those bound (`ExprTyper::generic_fn_value_type`). Any other callable used as a value (a generic short of its arguments, an overload set, a method) is SC094E at the parent that needs a value (`ExprTyper::propagate` -> `reject_callable_value`). A parenthesis passes a callable through.

Names reached through a dependent head (`T::Item`, `x.f()` on a bounded `T`) follow the bounds rule in [Interfaces.md](Interfaces.md#associated-types). Member types of a generic instance (`L<i32>::P`) are in [Generics.md](Generics.md#instantiation-model).

### Operators

`OperatorTyping.k`. Builtin operators on primitives follow the language reference's lattice §6 exactly: `u32 + i32` is an error, a shift unifies the right operand alone, compound assignment converts only the right operand. Results: a comparison is `bool`; `<=>` is `Ordering`; `??` on `T?` joins the inner type with the right operand; `^^` on primitives calls the `pow` lang item and needs an integer exponent; `&x` needs an lvalue and yields `*T`; `*p` yields the pointee as an lvalue. `===` needs a nullable operand and is not overloadable; the `==` its expansion runs on the unwrapped values is resolved here like any `==` and recorded on the `===` node for CoalesceLowering.

Pointer operands (`OperatorTyping::_type_pointer_op`): `p + n` / `p - n` with any integer `n` on either pointer kind, `p - q` (`isize`, raw pointers only: a safe pointer's provenance is one allocation, so a difference is never checkable), and `<` `<=` `>` `>=` on two pointers of one type are builtin and spelled as C++'s native pointer arithmetic. A `void` pointee is SC067E.

Non-primitive operands search:

1. the left operand's members and extensions under `op_name`;
2. free operator functions found by ADL in the modules of either operand's type (`MemberLookup::associated_scopes`);
3. for operators only, the file scope the record was declared in (`MemberLookup::declaring_scope`): otherwise a free `op *` beside a file-scope type is unreachable from every file, its own included.

Members and frees rank in one set (`OverloadResolution::resolve_mixed`), so a tie between them is ambiguous.

Derived comparisons: `!=` from `op ==`, `<` / `<=` / `>` / `>=` from `op <=>` (C++20's rewritten candidates without the reversed ones), and `==` / `!=` from `op <=>` when no `op ==` answers (a Kairo rule, never applied to an imported record). The derivation is recorded in `op_rewrite`. A comparison declared beside an `op <=>` wins every use and is warned about as shadowing the derived one (OperatorSignatureCheck, SC001W).

`==` / `!=` on two values of one ADT enum (one canonical type, so one instance of a generic enum, never a nullable) with no `op ==` compares variants, not payloads: X sets `tag_eq` and binds nothing, and OperatorLowering compares the tags through `EnumDecl::adt_tag_field`. A nullable ADT operand keeps builtin equality; two instances of one generic enum have no `==`.

Context-typed operands (`ExprTyper::is_context_typed`: the shapes deferred to selection, an untyped scalar literal, `null` / `&null`, a list literal, `.V`) take the other side's type on either side. The other operand is typed first and becomes the expected type, so `1 + b`, `[1, 2] == a` and `.North == d` work as their mirrors do. This changes typing order only; the tree, and evaluation, stay left to right. Where operands unify (arithmetic, bitwise, comparison) the context-typed one gets the other's type; `===` reads through the nullable. A shift's result is its left operand's type, so a literal left operand takes the expected type, else an integer count's (`1 << 4u8` is a u8 shift). Two context-typed operands keep their defaults (`1 << 4` is i32; `.A == .B` is SC123E). A dependent right operand gives a literal nothing to take (it keeps its default) and makes a `.V` unknown. `in` is not covered: its left operand is the right one's `op in` argument.

### Operators on builtin records

`[T]`, `{T}`, `{K: V}`, `[T;]` and `string` are records (lang items `Lib/builtin` declares; see [Containers](TypeResolution.md#type-resolution)), and every operator on one resolves through the record path any user type takes: its own and its extensions' members, bounds and witnesses, generic instances. A builtin type's declared operator wins; the hard-coded shapes are only the fallback for a builtin that declares nothing applicable.

- `for x in c` (StmtTyping `_iter_classify`): after `[T; N]` (no record), any record's `op in (self) -> yield T` is asked first; only then the fallback kinds `IterKind::Slice`, `Vector`, `Set`, `Map`, `String`, `Range`, `Yield`. A containment `op in (self, x)` is no iteration form. The fallback container kinds are gated by FeatureGateCheck.
- `c[i]` (MemberTyping `type_subscript`): a vector, map or string with no `op []` takes the built-in element shape; one with any `op []` resolves among them, so an index none of them takes is an ordinary overload error (a declared set is the type's whole subscript surface). Arrays, tuples and pointers have no members and are never asked.
- Every other operator (binary, comparison and the derived `!=` / `<`, compound assignment, unary, containment `in`, `op as`) has no identity branch ahead of the lookup: OperatorTyping and CastTyping gate on "is a record". The nullable operators (`x?`, `== null`, `??`, `===`) are language rules, not library operators, and stay ahead of the lookup ([Nullables.md](Nullables.md#passes)).

Kept by identity, since none of these is operator dispatch: list, set, map and string literal construction (LiteralTyping, OverloadResolution's list-literal target), lifecycle facts (ClassLifecycle; `Lib/builtin` declares no destructor yet), string patterns (PatternSpace, PatternCompilation, MatchLowering), eval-usage messages, and diagnostic spelling (`TypeUtil::str`).

### Checked parameters

X applies the bounded rule to a value of a bare parameter that has no `derives` bound (`TypeUtil::checked_param`); the per-construct table is in [Generics.md](Generics.md#instantiation-model). An operator (binary, unary, compound, `^^`, and the derived `!=`, relational and `a + b`), `===` (its `==`), `as T` and an f-string hole bind only to the bounds' requirements (`op ==`, `op as`, `repr`), called through the witness. With none it is R051E (unbounded) or R025E (bounds that do not declare it) at the definition, never a deferral.

The exception is the f-string hole: with no bound granting a string it is deferred (`FormatHole::deferred`), its put picked at each instance by the C++ template `__kairo_fmt_put`, and an instance whose value has no formatter is that instance's C++ error ([FormatStrings.md](FormatStrings.md#lowering)).

A checked parameter is never nullable (`t?`, `t == null` and `unwrap!(t)` get the non-nullable errors), and a pattern on it other than a binder or `_` is an error (PatternTyping); its match is analysed with an Opaque domain. A pack element (the binding of `for x in xs` over `...xs: T`) has the pack's type and is the same checked parameter, held to the bounds every element meets: `x as string` through a bound's `op as` is a witness call per element, and with no bound R051E. A generic ADT at dependent arguments (`Rep<T>`) is no composite for patterns and `==`: its variants are its pattern's (`PatternTyping::dependent_adt`, `PatternSpace::domain_of`), a binder reads through the instance, and the tag is read through `__kairo_which()`.

A call whose deduction binds a callee's `impl`-bounded parameter to the caller's checked parameter (`one(x)` with `x: T` in `fn <T>`, or a pack forwarded with `args...`, per element) is checked at the call, in CallTyping (`_check_forwarded_bounds`), against the caller's bounds: the callee's interface (at any arguments; a dependent mismatch is the instance's), or one deriving it, meets it, and any `derives` bound is taken on trust. None is R051E (with a fix-it adding ` impl I`) or R025E at the call, never left to the instance. A concrete argument is ConformanceChecking's, at the instance; a `: type` caller's is C++'s.

A `derives`-bounded parameter is outside `checked_param` (its conversions, f-string holes and patterns read only the interface bounds, so those still defer), but its operators follow the rule above through `TypeUtil::op_checked_param`: every operator site in OperatorTyping and MemberTyping's `op []` gathers from `TypeUtil::bound_scopes` (the interface bounds, then the bases). A base that declares the operator, or one the derivations build from (`!=` from `op ==`, a relational from `op <=>`, `a + b` from `op +=`), binds it as an ordinary member, emitted as a member call on the `T`; an operator no bound declares is R025E at the definition. A base's free operators are not consulted: they take the base by value, which a `T` does not slice into implicitly, as a derived record does not (SC063E, as on `Der == Der`).

### Casts

`CastTyping.k`. The written target is the result type. Dispatch on (source, target), first match, no fallthrough:

| Rung | Condition | Result |
|---|---|---|
| 1 | target = source + `const` | const cast, one way |
| 2 | target is `unsafe *X` | reinterpret; needs an unsafe context; source any pointer or an integer |
| 3 | target `*X`, source `*S`, related | upcast: static, redundant-cast lint; downcast: asserting (S must be polymorphic) |
| 3b | target `*X`, X a bare generic parameter whose `derives` bound is S or reaches it | CRTP downcast: `static_cast`, no vtable, no `unsafe` |
| 4 | target `*X?`, related | checked downcast, null on miss |
| 5 | static ladder | lattice I / W (lint) / E / U (unsafe context) / X (error) |
| 5b | plain enum <-> its exact underlying type | value cast |
| 5b' | `[T; N] as [T;]` | the array view, written out |
| 5b'' | a named function as a `fn` value | the function's fn-pointer value, written out |
| 5c | `fn op as (self) -> T` on the source | the user conversion; beats 5d |
| 5d | a one-parameter (converting) constructor on the target | construction; records `TypeCastExpr::resolved_ctor` |
| | none of the above | error |

- `as static` disables rungs 3 and 4 and errors on a dynamic answer. A static downcast is forbidden, except rung 3b, which a `derives` bound proves.
- `as const` asserts rung 1.
- `T? as T` is an error naming `??` / `unwrap!()`; there is no collapsing cast.
- Pointer and integer: `ptr as usize` needs no unsafe; `ptr as u8` is an error; `int as unsafe *T` needs unsafe; `int as *T` is an error; `*T as unsafe *T` needs unsafe.

**Closed enums.** Every plain enum not marked `@open` is closed (the parser stamps `EnumDecl::is_open`; TypeResolve ORs it over a forward declaration's chain; DeclImport sets it on every imported enum). A cast into a closed enum must produce a variant's value. A ConstEval-constant operand is checked at once (SC001E, fix-it `@open` on an enum this file declares); when the enum is declared below the cast, the check is deferred to the end of the walk. Any other operand sets `TypeCastExpr::enum_check`, and OperatorLowering wraps the operand in a range or per-variant test that crashes through the UnwrapFailed lang item on a miss ([Panic.md](Panic.md#model): a crash, not a panic). A closed enum's values past a dense set are its niche (EnumNiche); `@open` gives up both the check and the niche.

**Asserting downcast.** `p as *D` with D below p's polymorphic pointee sets `TypeCastExpr::asserting_downcast` and always warns (SC001W, fix-it appending `?`). OperatorLowering expands it into a dynamic cast that crashes when the source was non-null and the result is null, with a message naming the cast, both types and the site. It joins no panic set; `panic_sites()` collects these sites for that check, and PanicEffectChecking does not read it. Every crash message is built by `LowerSynth::crash_call`.

**Dependent pointee.** The asserting form on a dependent pointee is SC091E, except rung 3b: inside `class <X derives Mixin<X>> Mixin`, `&self as *X` / `*const X` is proven by the bound (`TypeUtil::bound_bases`, `Substitution::derives_from`, so a mixin chain's `*Rav<T>` casts down through `T derives Stmts<T>` too). It lowers to EmitIR's default `static_cast`, which adjusts the pointer for a mixin at a nonzero offset where a reinterpret would not. Dropping `const` is still SC030E. No bound, a bound on another parameter, an `impl` bound, or an unrelated `derives` bound stays SC091E. The bound itself is checked at the instance's use (ConformanceChecking: "'P' does not derive 'B'").

### Control expressions

`ControlTyping.k`.

- `if` / `match` / `try` as expressions join their arms (`Conversion::join`, [Conversions](#the-implicit-sequence)); every arm must then convert to the join.
- Closures type as their fn-pointer canonical. Parameters must be annotated; the return type is declared or inferred through a frame.
- `a..b` is `Range<elem>`; `await` on `Future<T>` is `T`; `spawn` / `thread` is `Future<T>`; `sizeof` / `alignof` are `usize`.
- `typeof x` is type-denoting; as a value it would be a TypeInfo, which does not exist (`var i = typeof x` is U001E). A `typeof e` type leaves T with no canonical (T files it in `SemaContext::typeof_types`); a variable's whole declared type is filled where the variable is typed (`StmtTyping::resolve_typeof_type`: `e`'s type as `var y = e` infers it, plus the cv written on the `typeof`; `var x: typeof x` is SC043E). Any other `typeof` type still without a canonical after typing (nested, or in a parameter, return, field or cast type) is U001E at the end of `ExprTyper::run`, never an unresolved type in codegen.
- `unsafe e` raises the unsafe depth. There is no `delete` expression: the destructor is `op finally`, `@destroy p` frees through the allocator and `x.finally()` runs the destructor early ([Ownership](Ownership.md#destruction-and-freeing)); `@cxx::delete p` needs a pointer.
- `({ s...; e })` types its statements in order, then `e` against the expected type. The result is a prvalue of `e`'s type with references and top-level cv dropped; a fixed array is an error.
- A named initializer looks fields up by name in the record's table and types values against the field type read through the receiver. An anonymous initializer needs an expected record type.

### Statements

`StmtTyping.k`. One frame per function or closure body holds the declared return type (null means infer) and the join of the returns seen.

- `return` without a value in a non-void function, with a value in a void one, or at all in a `!` function, is an error.
- `var x = e` writes the canonical into `type_`; `var x` with neither type nor initializer is an error; a `void` initializer is an error.
- Conditions and guards must be `bool`.
- `for x in xs` takes its element from the container, a map's (K, V) tuple, a string's char, a Range's argument, or `op in` (through `Yield<T>`); binders get it through their shorthands. Destructuring is by position or field name.
- Context bindings take the value's type. No pass lowers them (EmitIR's ICE names a ContextLowering that does not exist).
- `yield e` is typed against the function's `yield T`.
- A parameter default is typed against its parameter. It may not refer to another parameter or `self` (SC106E: a default is evaluated by a nullary thunk with nothing to read them from) nor be a slice literal (SC082E: the thunk would return a view of a dead array).
- An enum discriminant is typed against the underlying type (`u32` when none is written), the enum's own variants reading as that integer, then evaluated exactly by `ConstEval` (`Compiler/Sema/Check/`) into `EnumVariantDecl::value`. `~x` alone is taken in the type of `x` (so `~0` is all ones); the other operators work on the infinite two's complement form. A variant without one is the previous value plus one, the first 0; an ADT variant's value is its position. Only variants above the one being defined are evaluated. SC128E when a discriminant does not evaluate or does not fit; SC130E when a value repeats one above it (a closed-enum match's switch would have two equal case labels). A failed variant takes no part; ADTs and imported C++ enums (whose values are clang's) are not checked.

### Patterns

`PatternTyping.k`. X classifies each head a pattern names (variant, record type, or `const` / `eval` constant) into `Pattern::resolved_decl`, maps payload subpatterns to fields (names first, then positions) into `Pattern::field_decl`, and types every binder: binders take the scrutinee's type, literal and range patterns are checked against it, tuple patterns split. Constructor heads' legality, exhaustiveness and dead arms are PatternChecking's ([SemanticChecks.md](SemanticChecks.md#check-passes)).

### Outside X

Owned by later passes ([SemanticChecks.md](SemanticChecks.md#check-passes)): exhaustiveness and dead arms (PatternChecking); const-correctness beyond "adds const", including assignment to const (ConstChecking, not scheduled); panic effects (PanicEffectChecking, past the Typed barrier); access control (AccessCheck); `yield` versus `yield T`; the context-binding protocol. ADL never searches the global namespace: a type at TU scope associates no scope, by design ([MemberLookup.md](MemberLookup.md#member-lookup)).

### Tests

`Tests/Sema/ExprTyper/` holds golden `--print-sema` dumps. Among them: `literals.k`, `operators.k` (the lattice §6 table), `overloads.k`, `chains.k`, `casts.k` (one line per ladder branch), `control.k`, `bounds.k`, and `nomono.k`: a generic body whose every row is `<unknown>` with zero diagnostics. A failure there means something treats dependent as failed, and is the first bug to fix. The conversion matrix is under [Conversions](#tests-for-the-relation).

## Conversions

The conversion classes (I, W, E, U, X), the primitive rule set and the binary operator table are the language reference's (`conversion-lattice` §1 to §6, `primitives`, "Implicit Conversions"). This section states how `Compiler/Sema/Type/Conversion.k` implements the implicit relation.

### Ranks

Two ranks: Exact (class I) and Converted. Converted covers W, `T -> T?`, `*Derived -> *Base` (same safety), `! -> anything`, and the boundary and user rungs below. There is no ordering inside Converted; the tiebreaks that exist are overload-resolution rules ([Overload resolution](#ranking-and-tiebreaks)).

`-fno-implicit-conv` (`Conversion::implicit_enabled`) demotes W to None in the primitive rung and turns `abi_widen` off; nothing else reads it. It can therefore only turn a resolved call into an error, never change the winner (lattice §7).

### The implicit sequence

`Conversion::implicit(from, to)` (and `implicit_builtin`, the same sequence with the user rungs closed) tries, in order:

| Step | Rule |
|---|---|
| identity | `from == to`: Exact |
| never | `! -> anything`: Converted |
| C++ reference target | reference binding (`_bind_ref`); only imported signatures carry references |
| C++ reference source | read as its referee (lvalue-to-rvalue) |
| top-level cv | stripped on both sides; equal after stripping is Exact |
| primitives | `Conversion::classify(s, t)` == W: Converted (None under `-fno-implicit-conv`); any other class: None |
| `T -> T?` | one level per conversion: `T -> (T?)?` is None; `T? -> (T?)?` wraps the whole nullable; `T? -> U?` and `T -> U?` hold when the inners relate through the builtin sequence. Always Converted |
| pointers | same safety on both sides; no qualifier lost; derived-to-base (`Substitution::derives_from`); qualification conversion; `unsafe *T -> unsafe *void` (C's erasure, raw pointers only) |
| `fn` values | same signature, parameter modes and calling convention; the source's panic set within the target's ([Panic.md](Panic.md#effect-sets)); a raw `unsafe fn` widens to a `fn` value, never the reverse |
| user rungs | only in `implicit`: `[T; N] -> [T;]`, then `@implicit op as` |

`Conversion::classify(s, t)` is the rule-based primitive oracle (R1 to R5 of the lattice): an exhaustive decision over `BuiltinKind` pairs. bf16 -> f32 / f64 is W there (exact by construction); the lattice's R4 names no bf16 pair, which reads as E.

`char` (a 32-bit Unicode scalar) converts implicitly to an integer only when the target is unsigned and at least 32 bits or signed and wider than 32 (`u32`, `u64`, `i64`, ...), and from an integer only when the source is unsigned and at most 32 bits (`u8`, `u16`, `u32`); every other pair, and `usize` / `isize` either way, is explicit (`Conversion::_char_to_int`, `_int_to_char`). `u32 -> char` is unchecked: an invalid scalar is the programmer's error, never a trap. Since both directions are implicit, `char + u32` does not unify and needs a cast. C's `c_char` converts only explicitly, as its signedness is the target's, and so do `c_wchar` (width and signedness the target's), `c_char16` and `c_char8` (`is_c_character`); no C character type converts to another or to `char`. An untyped literal takes `c_char` in 0..=127, `c_wchar` and `c_char16` in 0..=0xFFFF, `c_char8` in 0..=255 (`literal_fits_int`): the values that fit on every target.

No C++ converting constructor is an implicit conversion: the user rungs below are the only user-defined ones, so constructing an imported type from another is written at the site. No enum converts implicitly to an integer either, an imported unnamed C++ enum included (DeclImport keeps it as an enum so its enumerators have a type); `as` is required.

`Conversion::join(a, b)` is the type of an `if` / `match` / `try`: identical types, else `Never` on one side, else the side the other converts to one way only through `implicit_builtin`. Neither or both directions is null and the caller errors (both directions would be a W-cycle). The join is a prvalue and carries no top-level cv.

### Boundary rungs

Two rungs apply only to arguments of imported callees; Kairo signatures, assignments and joins never see them.

**ABI widening** (`Conversion::abi_widen`, Converted). Asked only after the lattice said None, by `OverloadResolution::_rank_arg` and by CallTyping's post-selection re-check. Integer widening where `usize` / `isize` are the width range [32, 64] over every supported target and a fixed-width integer is [N, N]. S -> D holds iff max(S) <= min(D), strictly for uN -> iM, never for iN -> uM. So `u32` reaches a `size_t` parameter without `as` and `usize -> u64` holds, while `u32 -> isize` and `u64 -> usize` do not. The floor is 32 unless the target's pointer width is narrower (a 16-bit target refuses `u32 -> usize`); otherwise the target is never read, so the result is the same on every 32/64-bit triple. Pairs of fixed-width integers stay the lattice's alone. Off under `-fno-implicit-conv`.

**C string literal** (Exact). A plain string literal (not an f-string, not parenthesized) passed to an imported callee at a parameter that is a pointer of either kind to `const c_char` or `const u8` (`TypeUtil::is_c_string_param`), or a C++ `const T&` / `T&&` whose `T` is one (`vector<const char*>::push_back`: the reference binds the decayed pointer temporary; a non-const lvalue reference cannot, as in C++). It ranks Exact, as C++'s array-to-pointer decay does, so a non-generic candidate beats a template deduced from the literal's `string`. It is ranked by `OverloadResolution::_c_string_literal_arg` before `_rank_arg`. `CallTyping::finish_call_args` records the parameter type in `StringLiteralExpr::c_string` instead of checking convertibility; the node stays typed `string`, and StringLowering emits the bytes alone. A C `...` tail takes a literal the same way, as `unsafe *const c_char`; any other `string` there is SC001E with a `.c_str()` fix-it (C varargs cannot carry a C++ class). A non-literal `string` at a C string parameter gets the same fix-it on its not-viable note.

### User rungs

Both Converted, both closed to `join`, `unify_operands` (`implicit_builtin`) and to the recursion under `T -> U?`, so at most one applies per sequence and an arm or operand is never converted by one.

- `[T; N] -> [T;]` (`Conversion::array_views_as`): a view, nothing copied; a const array views only as `[const T;]`. The one container conversion the compiler owns, because an array has no body to declare an `op as` in. EmitIR spells it `Slice<T>(&(a)[0], N)` wherever a value is emitted against a record. `a[i..j]` on an array is the same view: MemberTyping resolves Slice's range `op []` on it and OperatorLowering wraps the base in an `ImplicitBoundaryCastExpr`.
- `@implicit fn op as (self) -> T` (`Conversion::implicit_op`): a member `op as` with the attribute (`OperatorFacts::is_implicit_conv`) whose result is exactly the target, read through the receiver's generic arguments (`_same_through`). No chaining. Nothing is inserted into the tree: `op as` is emitted as a non-explicit C++ `operator T`, so clang applies what Sema allowed. OperatorSignatureCheck rejects `@implicit` anywhere else (SC115E). Vector's `-> [T;]` in `Lib/builtin` is one: `[T] -> [T;]` is library, not compiler.

### Tests for the relation

`Tests/Sema/Conversions/gen_matrix.py` generates the primitive matrix tests from a `classify` coded from the language reference, never from the compiler. Every ordered pair is checked in each implicit context (`init`, `assign`, `arg`, `ret`, `join`, `eq`, `add`, `bitand`) and under `as`, and round-tripped at run time. A cell where the compiler disagrees is listed in `KNOWN_BUGS` and routed into its own XFAIL file, so the reference's verdict stays the assertion.

The relation must keep these properties over the full primitive set:

1. Reflexivity: `class(T, T) == I`.
2. Antisymmetry: W both ways implies equal types (a W-cycle makes overload resolution order-dependent).
3. Transitivity: W(A, B) and W(B, C) imply W(A, C), so results do not depend on chain length.
4. Value preservation: every W pair round-trips its bounds, zero, values around the bounds and random values.
5. Target independence: the class matrix is identical on every supported triple, including the `abi_widen` relation.
6. Totality: every ordered pair has exactly one class, with no `default:` fallthrough in the decision function.

Design intent, not implemented:

- A differential run for `-fno-implicit-conv`: compile the suite both ways, diff the per-expression type dump, and assert every difference is "resolved -> error", never "resolved(A) -> resolved(B)". Blocked on `--dump-type-info`, which is parsed but has no consumer (`Compiler/Driver/CompilerInstance.k`).
- One table (`conversions.def` or TOML) listing `(source, target, class)` for every pair, generating `Conversion::classify`, the reference's table, the property-test corpus and the type-dump legend. Today `classify` and the generator's `classify` are written separately and compared only by the matrix tests.

## Overload resolution

`OverloadResolution.k`, a component only ExprTyper calls.

### Viability

A candidate is viable when:

- every positional and named argument lands on exactly one parameter (positional, named, pack tail), after defaults;
- every placed argument reaches its parameter at Exact or Converted;
- a generic candidate's deduction binds every non-pack parameter;
- an imported C `...` function takes any number of trailing positional arguments, each Converted with no parameter to check.

Defaults are looked up across the whole redeclaration chain (`TypeUtil::param_default`): defaults accumulate over redeclarations, and the link being judged need not be the one that wrote one. An imported C++ callee can omit only trailing defaults (clang applies them by omission); a named argument that fills a parameter after an unfilled defaulted one is SC107E.

A forward declaration and its definition are one candidate (the representative). Specializations are skipped and paired later.

Packs: a one-type pack ranks each argument against its element. A type pack deduces one element per argument, by value (a literal its default), into `Deduction::packs`, opened even for an empty run; the instance carries the elements flat at the pack's position. An imported pack's pattern through a reference deduces the same way: `Args&&...` and `const Ts&...` take any argument, `Ts&...` only an lvalue. An imported template parameter with a C++ default (`enable_if_t<...> = 0`) is not required of deduction (`GenericParamDecl::ffi_has_default`): clang fills it. Its elements cannot yet be written as explicit generic arguments (not viable, with that reason).

### Ranking and tiebreaks

A candidate's rank is the worst of its argument ranks. Before ranking, hiding removes base methods ([MemberLookup.md](MemberLookup.md#member-lookup), `_hide`). Among the best-ranked, these tiebreaks apply in C++'s order; any other tie is ambiguous, even when one conversion looks narrower.

| Tiebreak | Rule |
|---|---|
| reference kind (`_ref_better`) | where both bound a C++ reference at Exact, an rvalue prefers `T&&` to `const T&` (so does the temporary a conversion makes, whatever the argument was: `push_back(x)` with `x: i32` into `vector<i64>`), and a non-const lvalue prefers `T&` to `const T&` |
| integer (`_int_better`) | where both bound a typed integer at Exact, the C type the target spells that width with beats a same-width alias (i32 prefers `int` to LLP64's `long`); C maps by width, so both are Exact to Kairo |
| float literal (`_flit_better`) | where an untyped float literal bound Exact to a non-dependent float, f64 beats every other float, as C++'s `16.0` is a double; a lone f32 parameter still takes the literal |
| generic | a non-generic candidate beats a generic one (otherwise `fn f(i32)` beside `fn <T> f(T)` is ambiguous on every call) |
| specialization (`_partial_order`) | among generic candidates still tied, the one more specialized than every other ([temp.func.order]) |

The implicit object parameter ranks as [over.ics.rank] says. Without a ref-qualifier any object binds and cv orders two candidates (of two whose cv differs, the less qualified wins, so a plain object takes `std::atomic`'s `load() const` over `load() const volatile`; `const` against `volatile` stays a tie, `Candidate::recv_quals`). With one (`ffi_ref_qualifier`) the object parameter is a reference: `q() &` takes an lvalue (or anything, if const), `q() &&` an rvalue, and between two qualified methods an rvalue object prefers `&&`. The object's category is `ChainInfo::receiver_cat`, passed as `OverloadResolution::recv_cat`.

Diagnostics owned here: no viable candidate (candidate notes capped), ambiguous call (SC064E), name not callable.

### Receiver seeding

A member's parameters can be bound from the receiver before any argument is ranked; this sets `seeded`. Once seeded, a dependent parameter ranks as its substituted type, so a literal takes it and an argument converts to it instead of re-deducing it, and an extension whose parameters are still unbound is not viable.

- An extension member (`Deduction::bind_from_extension`, after the receiver is judged, before placement): the extension's target is unified with the receiver, so `extend <T> Vec<Box<T>>` binds what it names and a receiver it does not match makes the candidate non-viable. No receiver, or a dependent one, binds nothing (`Vec::m(v)` deduces from its `self` argument).
- A member of a generic record reached through a concrete instance (its own pattern's, a partial's, or a constructor) (`Deduction::bind_from_record`): on `Opt<i32>`, `fn Opt(self, v: T)` takes an i32 and never deduces `T := NullT` from the call, so it cannot tie an exact `fn Opt(self, n: NullT)`. Members a generic base declares are read at the base instance ([Generics.md](Generics.md#instantiation-model)). An inherited member of a non-generic base keeps deducing; a dependent receiver uses `member_through` (deferred mode).
- A qualified requirement call (`Container<i32>::get(b, 0)`) seeds from its qualifier through `declaring_instance(f, Q)`; a call through a bound (`c.get(1)` with `C impl PW<i32>`, or an operator on such a `C`) seeds from the first interface bound of the receiver parameter (`TypeUtil::bound_ifaces`) whose `declaring_instance` is non-null, so `-> Wrap<V>` reads `Wrap<i32>`. A non-generic interface binds nothing. The associated-type side is [Interfaces.md](Interfaces.md#associated-types).

### Deduction

`ArgumentDeduction.k` over `Substitution.k`. Deduction is a structural unification of the parameter's canonical against the argument's, binding `(owner, index)`; conflicts fail, and there is no common-type search. At the top level unification may succeed through the implicit relation (Converted); inside a structure it is exact or nothing. An imported function template's defaulted type parameter that no argument deduced is bound to its default before completeness is judged (`Deduction::fill_ffi_defaults`, [temp.deduct]/5), so `template <class S, class R = Box> R wrap(const S&)` returns a Box; value parameters (`enable_if_t<...> = 0`) are left to clang. `substitute` rebuilds through the type store and goes through the registry for a concrete record. `member_through(recv, mt)` reads a member type through the receiver's arguments. `replace_self(t, I, T)` reads an interface member through a bound (`-> Self` is `T`).

### Deferred constructor calls

`OverloadResolution::resolve_deferred` resolves a constructor call whose record is dependent (`Box<T>(p)` in a generic body) against the pattern's constructors. Each parameter is read through the call's record arguments (`member_through`). A parameter still dependent, or a dependent argument, is viable for anything and unranked (`assumed`); a concrete pair ranks, and errors, as in any call. An Exact candidate that assumed nothing beats an assumed one, which keeps every generic record's `@move fn R(self, other: Self)` from making its other constructors ambiguous. A unique winner writes `ctor_decl` and `arg_map` as a concrete call does.

### Imported function templates

An imported function template Kairo found viable is deduced again by clang (`_clang_substitute` -> `ForeignInstantiate::deduce_call`: `Sema::DeduceTemplateArguments` on the written generic arguments and the call arguments as opaque expressions of their types and categories), so substitution failure removes it as in C++: `enable_if` on a defaulted parameter, the return type or a parameter, `decltype` / `void_t` expressions, requires-clauses. libc++'s `make_unique` split and `vector::assign` / `insert`'s iterator-versus-count pair depend on this.

- Only SFINAE verdicts (SubstitutionFailure, ConstraintsNotSatisfied, InvalidExplicitArguments) remove a candidate; a deduction mismatch keeps Kairo's verdict. The reason given is clang's own ("template ignored: requirement '...' was not satisfied").
- A removal that read a Kairo record through its TypeExport stand-in (layout only, no methods, so a concept probing `b.len()` is false for it) is soft (`Candidate::soft_rejected`): the candidate stays viable and loses any tie to one clang kept. `make_unique<Cp>(4)` still drops the array overloads, and a lone concept-constrained template taking a Kairo record still binds.
- Kairo candidates in the set are not touched; ranking among survivors is unchanged.
- A declared return type that is itself the SFINAE (opaque to Kairo) reads clang's specialization's (`OvlResult::cxx_ret`).
- An argument still dependent (`x: T` in a generic body) defers the verdict: a tie only among such candidates is `OvlOutcome::Dependent`, emitted as the dependent C++ call it is (`EmitIR::_dependent_imported_set`).
- An imported template is emitted with the generic arguments the call wrote and nothing else; clang deduces the rest, the only spelling that keeps a forwarding `Args&&` an lvalue reference where it should be.
- A function template's USR gets the ODRHash of its constraints and `decltype` return appended (`TypeImport::_tpl_discriminator`); the USR generator drops both, which made two such templates one registry entity.

## Known gaps

- A tie through an assumed candidate. When the best deferred constructor candidates tie only because one was assumed (or a lone assumed winner has a viable rival), the outcome is `Deferred`: no diagnostic, the call typed, `ctor_decl` null, and EmitIR's `Rec<T>(args)` lets clang pick per instance. An ambiguity there surfaces as a clang error on the instance. Closes when bounds give each parameter enough to rank.
- A `const` binding's constness is not in its type, so a const array bound to `[T;]` is caught by clang, not by X.
- A view of a local that escapes (returned, stored) and a callee that retains a slice argument are not diagnosed; both are left to the planned escape analysis.
- A call whose result is an lvalue or a record keeps C++'s argument order ([Lowering.md](Lowering.md#passes), SequenceLowering).
- Elements of an imported pack with C++ defaults cannot be written as explicit generic arguments.
- `typeof` as a value needs TypeInfo, which does not exist.
- `--dump-type-info` has no consumer.
