# Lowering

The lowering stage reduces the checked tree to the C++-shaped core that EmitIR renders ([Codegen.md](Codegen.md#model)). It runs per TU between the `Checked` and `Lowered` phase gates ([Pipeline.md](Pipeline.md#sema-pass-order), [Pipeline.md](Pipeline.md#phase-barriers)). The passes live in `Compiler/Sema/Lower/`; `LowerSynth.k` holds what they all mint (interned identifier tokens, integer and byte literals, fresh `__kairo_` locals, calls, statement expressions, and the purity test SequenceLowering orders by).

Rules every pass keeps:

- Every pass is an ASTWriter. A node kind a pass owns that reaches codegen is an ICE naming the pass; codegen never grows an arm for a node a lowering removes.
- Every pass walks a closure's body as it walks a function's (the ASTWriter descends into `ClosureExpr`).
- The order is sugar first, control flow second, lifecycle last. A pass's position is fixed by what it must see before or after another pass; the constraints are stated in the table and in `Sema.k`.
- Generators need no lowering (a C++ coroutine, spelled by EmitIR), and destruction none (C++ destroys locals at scope exit).
- PatternCompilation, which builds the decision tree MatchLowering renders, is a check, not a lowering: it runs last in the check stage ([SemanticChecks.md](SemanticChecks.md#check-passes)).

## Pass order

`Compiler/Sema/Sema.k::_stage_lowerings` owns the order; this table is that function's sequence.

Rows 1 to 28 are also `LowerStep` (`Compiler/Sema/Lower/LowerStep.k`), whose declaration order is this order. Each of those passes starts its `run()` with `SemaContext::begin_lower(<its step>)`, which in a debug build ICEs unless the step just before it is the last one that started, and `_stage_lowerings` closes the list with `end_lowerings` after StringLowering. A pass moved, added or dropped without moving its step is an ICE at that pass, so the position constraints below are checked, not only stated. Rows 29 to 31 are not tree rewrites and keep their own gates.

| # | Pass | Position constraint | Specified in |
|---|---|---|---|
| 1 | ImplicitConvLowering | first: X records each implicit conversion through an extension's `op as` by the expression node, and every later pass may replace nodes | [Passes](#implicitconvlowering) |
| 2 | VariantInitLowering | right after ImplicitConvLowering: X's variant facts are on the nodes X wrote them on, and every later pass sees one node kind for a construction | [Passes](#variantinitlowering) |
| 3 | EnumLayoutLowering | before every body rewrite: every later pass reads ADT values through the layout record's query surface | [Passes](#enumlayoutlowering) |
| 4 | ExprBodyDesugar | every later pass sees a block body (SequenceLowering hoists into statements) | [Passes](#exprbodydesugar) |
| 5 | WhereDispatchLowering | after ExprBodyDesugar; before every other body rewrite and before CopyMoveLowering | [Passes](#wheredispatchlowering) |
| 6 | FieldInitLowering | clang takes no statement expression at class scope; later passes meet the initializer as a `return` | [Passes](#fieldinitlowering) |
| 7 | CtorInitLowering | before any pass inserts a statement: the cut is a statement count | [Passes](#ctorinitlowering) |
| 8 | CopyMoveLowering (moves) | before any pass rebuilds an expression | [Ownership.md](Ownership.md#copy-and-move) |
| 9 | ScriptLowering | after CopyMoveLowering; before FinallyLowering and the nullable block | [ScriptMode.md](ScriptMode.md#desugaring) |
| 10 | PanicLowering | after ScriptLowering and CopyMoveLowering; before FinallyLowering, LabelLowering, CallLowering, SequenceLowering | [Panic.md](Panic.md#passes) |
| 11 | FinallyLowering | after CopyMoveLowering and PanicLowering; before every other body rewrite | [Passes](#finallylowering) |
| 12 | TupleLowering | after CopyMoveLowering; before OperatorLowering (an operator on `t.0` sees a field path) | [Passes](#tuplelowering) |
| 13 | CoalesceLowering | nullable block, step 1 | [Nullables.md](Nullables.md#passes) |
| 14 | NullTestLowering | nullable block, step 2 | [Nullables.md](Nullables.md#passes) |
| 15 | NarrowedAccessLowering | nullable block, step 3 | [Nullables.md](Nullables.md#passes) |
| 16 | NullableTypeLowering | nullable block, last; after CopyMoveLowering; before OperatorLowering | [Nullables.md](Nullables.md#passes) |
| 17 | OperatorLowering | after the nullable block (`===`'s `==` may be a user operator) | [Passes](#operatorlowering) |
| 18 | FStringLowering | after OperatorLowering (a hole may hold a user operator); before StringLowering | [FormatStrings.md](FormatStrings.md#lowering) |
| 19 | CallLowering | before SequenceLowering: a default thunk's call is an impure argument | [Passes](#calllowering) |
| 20 | IterLowering | before ExtensionLowering (an extension `op in` is called through a chain), SequenceLowering and ListLiteralLowering | [Passes](#iterlowering) |
| 21 | RangeLowering | after IterLowering, which consumes loop ranges, and OperatorLowering | [Passes](#rangelowering) |
| 22 | MatchLowering | after IterLowering and RangeLowering; before SequenceLowering and StringLowering | [Passes](#matchlowering) |
| 23 | LabelLowering | after IterLowering (labels on minted loops) and MatchLowering (an arm's `break L` moves with the arm) | [Passes](#labellowering) |
| 24 | ExtensionLowering | before SequenceLowering, which orders the receiver | [Passes](#extensionlowering) |
| 25 | SequenceLowering | after OperatorLowering (operators are calls); before ListLiteralLowering | [Passes](#sequencelowering) |
| 26 | SequenceCheck | right after SequenceLowering; from the next step on `SemaContext::sequenced()` is true | [Passes](#sequencelowering) |
| 27 | ListLiteralLowering | after OperatorLowering and SequenceLowering | [Passes](#listliterallowering) |
| 28 | StringLowering | last rewrite: a literal is pure until it becomes a constructor call | [Passes](#stringlowering) |
| 29 | PurityInference (-finfer-purity, on by default) | after every lowering (judges every call a lowering minted); before ParamPassInference, which must leave an inferred-const function's parameters by value | [Passes](#purityinference) |
| 30 | ParamPassInference | after every lowering: reads the tree EmitIR renders | [Passes](#parampassinference) |
| 31 | EnumLayoutSweep | after every lowering: instances a lowering minted are in the registry | [Passes](#enumlayoutlowering) |

`PurityInference` is `FnPurityCheck::infer` and `ParamPassInference` lives in `Compiler/Sema/Check/`; `SequenceCheck` in `SequenceLowering.k`; the sweep is `EnumLayoutQuery::sweep`. A `using Base::name;` for merged base overloads is not a pass: InterfaceEmitter writes it where the class is spelled ([MemberLookup.md](MemberLookup.md#inheritance)).

Not implemented:

- `TypeQueryLowering.k` is a stub; `sizeof` / `alignof` emit as C++ `sizeof`, and `typeof` as a value has no lowering.
- CopyMoveLowering's copy half ([Ownership.md](Ownership.md#copy-and-move)).
- Context bindings: EmitIR ICEs on a `ContextBindingStmt`, naming a ContextLowering that does not exist.

## Passes

Passes specified in another document have only their row above.

### ImplicitConvLowering

`ImplicitConvLowering.k` (`LowerStep::ImplicitConv`). Each expression X accepted through an extension's `@implicit op as` becomes a `TypeCastExpr` with `resolved_op` (and `op_instance` for a generic extension), which OperatorLowering and ExtensionLowering turn into the call of the scope member ([MemberLookup.md](MemberLookup.md#emitted-shape)). A member's `op as` is left to C++, which applies it as `operator T`. The sites include an initializer, an assignment, a by-value or `const` argument, a return, a struct-literal field, list and tuple elements, constructor and method arguments, user-operator and subscript operands, a closure argument, a default argument, and a C++ callee's `const T&` parameter. It runs first because X records the conversion by expression node, and every later pass may replace nodes.

### VariantInitLowering

`VariantInitLowering.k`. An ADT construction becomes a `VariantInitExpr` built from X's `variant_decl` / `field_decl` facts ([ExprTyping.md](ExprTyping.md#expression-typing)): the payload in declaration order (what a C++ braced list runs), `source_order` holding the position each field was written at (what Kairo runs), the node's type (the instance for a generic enum) and category kept. SequenceLowering binds the fields to locals when the two orders differ and a field has side effects. A plain enum's `.V` becomes a `NamedIdentExpr` bound to the enumerator and typed as the enum, which EmitIR spells as `Dir::North`. EmitIR spells a `VariantInitExpr` as a constructor of the enum's layout record.

### EnumLayoutLowering

`EnumLayoutLowering.k`. Every ADT pattern gets one StructDecl, `EnumDecl::adt_layout`:

- a tag enum `__kairo_Tag` (the variants by name and in order, so a tag is a variant's position);
- one payload struct per variant with a payload (`is_adt_payload`; its fields are that variant's payload FieldDecls);
- the tag field (`adt_tag_field`) and an anonymous union with one member per payload (`EnumVariantDecl::adt_member`);
- five flags when the enum is generic;
- FunctionDecls with no Kairo body, marked `adt_role` / `adt_form`: a constructor per variant, the special members (all three forms of each when generic, the one its lifecycle facts select otherwise), and the private destroy and construct-from helpers.

Every minted declaration's `semantic_dc` is the EnumDecl. Nothing is retargeted: RecordTypes keep naming the enum, and codegen reaches the record only through `adt_layout`. A non-generic ADT whose facts are Unknown (a payload that is a generic instance) is rejected first by FeatureGateCheck (SC116E), so the pass's ICE on one is an invariant.

**Tag type and constructors.** The tag is the enum's `derives` type, else the narrowest of u8 / u16 that holds the variants (a too-narrow `derives` is R001E in TypeResolve); tags stay dense `0..N-1`. A variant whose fields are all trivially copied and destroyed is built through one field constructor (`EnumVariantDecl::adt_ctor`: Fields); every other through the lambda one. A generic ADT has both, the site choosing by `VariantInitExpr::field_ctor`.

**Niche layout.** An ADT with one payload variant of one field beside dataless ones is niche-shaped (`adt_niche_shape`): it is laid out with no tag when the field's niche (`EnumLayoutQuery::niche_of`) covers the dataless variants and the field is trivial. This is decided here for a non-generic ADT (`adt_niche`) and by C++ per instance for a generic one (a constrained partial specialization); Sema predicts the instance's layout and `EnumLayoutQuery::sweep` records it on each InstanceEntry for codegen's `static_assert`s. `__builtin_niche_of<T>()` (the NicheOf lang item) is answered here as a literal.

**Tag in the common prefix.** A non-generic, non-niche ADT whose payload fields are all builtins, pointers or plain enums keeps its tag in the payloads' common prefix (`adt_tag_member` / `adt_prefix_tag`): each payload struct starts with the tag and the union's first member holds only it.

**Query surface.** Every read and test of an ADT value goes through `EnumLayoutQuery` (`tag_read`, `variant_test`, `payload_ref`, `field_ref`, `same_variant`); MatchLowering and OperatorLowering never spell the layout. A generic ADT and a niche-filled one also get `__kairo_which()` (`AdtRole::Which`), which the query uses where it cannot predict the instance's layout.

**Pack-expanded variants.** A variant `Err { e: E }...` (always the last, its pack fields typed bare `E`; [Panic.md](Panic.md#effect-sets)) is one constructor per element of the instance's pack. Its payload struct is a C++ template over the element (`StructDecl::adt_pack_param`), its union member a `__kairo_pu<P<E>...>` (the preamble's recursive union), its constructor `(vt<p>, vt<K>, f)`, and its tag the variant's plus K. Every index EnumLayoutQuery takes is expanded (`adt_variant_at` / `adt_expansion_at`): element k of the pack variant at position p is p + k, which is also its tag; a payload read carries K on its chain step (`Step::pack_index`). Pack arguments are deduplicated where the type is formed (`decl_dedup_pack_args`, in `CanonicalTypes::record` and the registry), so equal elements are one variant; a `PackSetOrder` the driver installs in both also fixes the order for a lang item that wants one. Under type-id tags (AdtLayoutKnobs, the Panic item) element k's tag is its type's id (`EnumLayoutQuery::tag_value(t, en, index)`). Construction and patterns pick the element by payload type (`VariadicEnum`; ControlTyping and PatternTyping record `variant_pack` / `Pattern::pack_index`); at a dependent type either is SC116E. Such an enum has no niche: the tag niche is per instance.

### ExprBodyDesugar

`ExprBodyDesugar.k`. An expression-bodied function becomes the block it abbreviates: `return e` when the written signature has a return type other than `!`, else `e;`. The written signature decides because it is what EmitIR spells the return type from (no written type emits `void`). A closure's expression body is the same rewrite, decided by its resolved return type (`ControlTyping::type_closure` writes an inferred one back), so `void` and `!` take `e;`. The expression moves unchanged. EmitIR's `_unsupported_body` ICEs on a remaining expression body.

### WhereDispatchLowering

`WhereDispatchLowering.k`. Each group in `where_groups` becomes one function. The lead keeps its identity (every call names it) and becomes the dispatcher, with fresh parameters: `if g0 { return K0(args) } ... return Kn(args)`, guards in dispatch order, each retargeted by position to the fresh parameters, the last call untested. Every member hands its parameters and body to a minted `priv` candidate `__kairo_where_<name>_<k>` (k is the member's source rank, `LowerTargets`; members at one position, made by one macro invocation, rank in dispatch order among themselves), so no body is rewritten; a non-lead member leaves the tree. A forwarded by-value MOVE parameter is recorded in `move_sites` for CopyMoveLowering.

### FieldInitLowering

`FieldInitLowering.k`. A class, struct or union field's initializer becomes its C++ default member initializer; a union's fields are lowered as a struct's (`transform_union_decl`).

- A constant (an integer ConstEval folds that fits the field, `true` / `false` on a bool, `&null` on a raw pointer) is recorded on the field (`FieldDecl::init_fold`, the value in `init_neg` / `init_mag`) and spelled in the class.
- Anything else becomes `fn __kairo_init_<f>(self) -> T { return <init> }` (`LowerTargets::field_init_thunk`), appended to the record's methods and stamped as `FieldDecl::init_thunk`; the default calls it. The thunk is a method, so a bare member the initializer names is read through `this` (InitCheck guarantees that member is built first). Its body goes out of line like every user body ([Pipeline.md](Pipeline.md#invariants)).
- A static field folds or thunks the same way; its thunk takes no `self`, and the value is its out-of-line definition's ([Codegen.md](Codegen.md#interfaceemitter)).
- An array field's list literal is lowered one element at a time, since no C++ function returns an array: a thunk per element, `__kairo_init<i>_<f>` (`LowerTargets::field_init_elem_thunk`), stamped in order as `FieldDecl::init_elems` (`init_fold` Elems); the default is `= {__kairo_init0_f(), ...}`.

`init` is null afterwards (moved into the thunk). Eval fields and every other array initializer keep `init`; FeatureGateCheck rejected them.

### CtorInitLowering

`CtorInitLowering.k`. A constructor that CtorInitCheck split has its body cut into exactly two blocks, `{ {S_pre} {S_post} }`, at `ci_split`, and `ci_cut` set. Nothing is renamed or minted, so Sema's view of the record is unchanged. It runs right after FieldInitLowering because the cut is a statement count: every later pass may insert statements, and each lands inside its own half.

### FinallyLowering

`FinallyLowering.k`. `finally { body }` becomes a StructDecl declared in the function body whose `op finally` is the body, plus a local of it where the statement stood (`__kairo_FinK` / `__kairo_finK`, LangItems). C++'s rule for locals is the language's `finally`: destroyed at the block's end, on every exit, LIFO with the block's other locals. Captures (FreeVarScan, `CaptureAnalysis.k`) are the free automatic locals and the enclosing function's parameters, each by address, in first-use order; the enclosing `self` is the `__kairo_owner` pointer field. Each use in the body is rewritten to `(*self.<field>)`. Statics and globals are not captured. EmitIR emits the record in place (`_local_record`), Speller names a function-scope record by its leaf, and EmitPlan never admits one. A `finally` in a closure is the same record declared in the lambda's body and homed in the enclosing function; the closure's parameters are captured like a function's, and a binding the closure holds by pointer is reached through that pointer.

The explicit destructor call `x.finally()` runs that same `op finally` early, on a local stored in a union ([Union-storage locals](#union-storage-locals)); `@cxx::new` / `@cxx::delete` (and their array forms) lower to the plain C++ `new` / `new[]` / `delete` / `delete[]` expressions, with the constructor chosen by the ordinary overload resolution, and are never routed through `create` / `destroy` ([Ownership](Ownership.md#destruction-and-freeing)).

### TupleLowering

`TupleLowering.k`. A tuple is its arity's record: `(A, B)` is `Tuple2<A, B>`, a generic struct with fields `_0: T0, _1: T1`, no constructor and no methods, minted on first use (`AST/Context/TupleRecords`, one per arity per build, homed in the builtin root TU, in no table) and canonicalized by T through `SemaContext::tuple_record`, the one builder, so a written tuple, a literal's and a substitution's share one identity and one registry entry. No canonical is a TupleType after T. `TypeUtil::is_tuple` / `tuple_elems` / `tuple_field` key on `StructDecl::tuple_arity` of the pattern, never the name (`LangItems::tuple_record_name` is the only speller). X binds `t.1` to the field `_1` (an lvalue).

The pass rewrites:

- a literal into the record's NamedInitializerExpr (fields in element order), built as the literal's type, which is the expected tuple when the literal converted element by element; a numeric element whose numeric type differs from its field's is written as a cast, since a braced initializer refuses a narrowing conversion (a record element's `op as` conversion is OperatorLowering's);
- an index step into a Name step bound to its field, in place (the node keeps its identity for `move_sites`);
- `var (a, _, c) = e` into one hidden local for the value (`const T&` to an lvalue, by value to a prvalue) and one local per binder off its fields, moved out of the by-value local.

A match's tuple-literal scrutinee is left to MatchLowering, which binds each element as its own column. `for (k, v) in xs` is IterLowering's. Struct destructuring (`var {r, g} = c`) is SC116E (FeatureGateCheck). EmitPlan marks a tuple record OWN in every plan, and InterfaceEmitter defines it under `__KAIRO_TUPLE_<N>`, so only the arities a TU names are emitted and two headers in one C++ TU agree.

### OperatorLowering

`OperatorLowering.k`. Every user operator becomes the call X selected (`resolved_op`, `op_via_free`, `op_rewrite`):

| Source | Lowered |
|---|---|
| `a + b`, member | `a.op+(b)` |
| `2 * v`, free | `op*(2, v)` |
| `-v` | `v.op-()` or `op-(v)` |
| `x++` | `x.op++(0)` (the `int` dummy C++ needs) |
| `x in xs` | `xs.op in(x)` (the right operand is the receiver) |
| `a[i]` | `a.op[](i)` |
| `x as T` with `op as` | `x.op as()`, or for an extension's the call of its scope member through ExtensionLowering; a converting constructor becomes the construction |
| `x ^^ n` | `pow(x, n)` (the lang item) |
| `a != b` from `op ==` | `!(a.op==(b))` |
| `a < b` from `op <=>` | `((a.op<=>(b)) as i8) < 0` |
| `a == b` on an ADT (`tag_eq`) | variant comparison through `EnumLayoutQuery::same_variant` |
| `a += b` with `op +=` | `a.op+=(b)` |
| `a += b` with only `op +` | `a = a.op+(b)`, `a` evaluated once |

It also expands the checked casts X marked: `enum_check` into a range or per-variant test that crashes through UnwrapFailed, and `asserting_downcast` into a dynamic cast that crashes on a non-null miss ([ExprTyping.md](ExprTyping.md#expression-typing), Casts). `a[i..j]` on an array wraps the base in an `ImplicitBoundaryCastExpr`.

### CallLowering

`CallLowering.k`. After it every call has one positional argument list in parameter order; `NamedArgExpr` is gone and `arg_map` is empty.

- A default becomes a nullary thunk (`LowerTargets::default_thunk`), one per entity and parameter index, stamped as `ParamDecl::default_thunk` at that index on every link of the redeclaration chain and spliced beside the declaring link; a default written on an out-of-line definition becomes a member of the owner. `default_val` is moved into the thunk. The thunk of a member of a generic extension is a member of the same extension scope, so its template parameters are the extension's, then the member's own; the call registers its instance with the member call's instance arguments, and EmitIR spells them, since a nullary call deduces nothing.
- Explicit arguments evaluate left to right as written, whatever parameter they name; defaults evaluate after them, in parameter order.
- A pack over one type is a `Slice<E>` by value (`ParamDecl::pack_type`) over a backing array alive for the call's full-expression. A type pack (`fn <...T> f(...xs: T)`, `param_is_type_pack`) is a C++ parameter pack, its run left one argument per element. An imported pack (`Args&&... args`) is one too: its element is the expansion's pattern, which may be a reference to the pack.
- Dependent calls are left as written.

### IterLowering

`IterLowering.k`. X records each ranged `for`'s `iter_kind`, `iter_elem` and, for a user `op in`, `iter_op` and `iter_inst` (a generic one's instance; an extension's on `[T]` is called with X's arguments, never clang's). The pass renders a block of hidden locals and a `while` that advances before its body, so `continue` needs no step. An `op in (const self)` chosen for a mutable iterable (a loop with no mutable pointer binder) is called as `(*static_cast<const X*>(&x)).op_in()`. Over an `op in` that yields `*T` / `unsafe *T` (`RangedForStmt::iter_yield`), `iter_elem` is the yielded pointer: a single `*x` binder is initialized with `*it.current()` itself (the pointer the generator yielded, never the address of the promise's slot), and any other binder list is bound over `**it.current()`, the element. Over a tuple yield with a pointer element (`IterYield::Tuple`) the yielded tuple is named once by reference (`auto& __e = *it.current()`) and each binder takes its field: over a pointer element `*v` is `__e._i` itself and `v` copies `*__e._i`; over a value element the field as any tuple binder. An `op in (const self)` chosen for a mutable iterable (a `const` binder) is called as `(*static_cast<const X*>(&x)).op_in()`.

Lowered: `a..b` and `a..=b` (never computes past `hi`, so `lo..=T::MAX` cannot overflow), Range values (`inclusive` read at run time), `[T; N]`, `[T;]`, a user `op in (self) -> yield T` (including a builtin container that declares one), and imported C++ ranges ([stmt.ranged]: member `begin()` / `end()`, else free ones by ADL). Only an imported record takes the C++ protocol: `op in` is a Kairo type's one way to be iterable, so a Kairo class's `begin()` / `end()` never route a `for`. For a C++ range X resolves both calls on the range's cv and types `__it != __end`, `*__it`, `++__it` over two hidden locals it mints (`RangedForStmt::cxx_*`), so the loop's operators are chosen like any expression's; this pass places them and runs OperatorLowering over them, since they enter the tree after that pass. A pointer iterator's `++` is minted typed.

A `for` over a type pack (`IterKind::Pack`) is left for EmitIR, which unrolls it as a fold, one lambda copy per element.

Binders: plain `x` copies; `*x` points at the element (at a per-iteration copy over a range or a prvalue `*__it`); `(k, v)` binds the tuple element once (a const reference when it is a stable lvalue, a copy otherwise) and each binder off its fields.

Not lowered: the Vector, set, map and string shapes that declare no `op in`, and nullable binders.

### RangeLowering

`RangeLowering.k`. Every range that reaches it is built as an aggregate by shape (a designated initializer, so C++ evaluates `f()..g()` left to right with no sequencing):

| Range | Record |
|---|---|
| `a..b`, `a..=b` | `Range<T>{.begin, .end, .inclusive}` |
| `a..` | `RangeFrom<T>{.begin}` |
| `..b`, `..=b` | `RangeTo<T>{.end, .inclusive}` |
| `..` | `RangeFrom<usize>{.begin = 0}` |

Open ranges are valid only as a subscript index (X rejects them elsewhere). OperatorLowering already turned `a[r]` into `a.op[](r)`, so a subscript's range arrives as an ordinary argument.

### MatchLowering

`MatchLowering.k`. Every `match` becomes labels, gotos and switches over a once-evaluated scrutinee, rendering PatternCompilation's decision tree; the pass decides nothing about the patterns. A match CoalesceLowering left on the value of a `T?` is an ordinary one by then.

- The scrutinee is evaluated once: a scalar or prvalue into a local, a class lvalue by `const T&`. A tuple literal is never built; each element is its own local, in order.
- A switch holds only gotos, and every label sits at the match's top level with arm bodies in blocks of their own, so no goto crosses an initialization and `break` / `continue` in an arm reach the enclosing loop. Labels come from LowerTargets with a per-function match number.
- `var x` copies its occurrence; `const x` is `const T&`. A `var` binder that is an arm's whole value is moved out.
- The value form records the arm index and selects the arm's value at the end; a one-leaf tree and a single test between two leaves take cheaper shapes.
- An exhaustive switch over an ADT's tag, or over a closed plain enum (its `as` is checked, so it holds no undeclared value), defaults to `__builtin_unreachable()` (`CodeGenOptions::adt_tag_policy`; a trap under `--hardening=enum-tags`). An `@open` or imported enum's and an integer's default to UnmatchedPolicy. An ADT with no tag (niche-filled) is an `if` chain of `EnumLayoutQuery::variant_test`, the last variant untested.

### LabelLowering

`LabelLowering.k`. `break L` / `continue L` become gotos past the loop or to the end of its body.

### ExtensionLowering

`ExtensionLowering.k`. A call to an extension member becomes the call of the static member it is ([MemberLookup.md](MemberLookup.md#extensions)), with the receiver as argument zero:

| Source | Lowered |
|---|---|
| `a.m(x)` | `m(&a, x)` |
| `p->m(x)`, `(*p).m(x)` | `m(p, x)` |
| `self.m(x)` | `m(self, x)` |
| `make().m(x)` | `m(__kairo_tmp(make()), x)` (materialized; lives to the end of the full-expression) |
| `d.m(x)`, found on a base | `m(static_cast<Base*>(&d), x)` |
| `Foo::m(a, x)` | `m(&a, x)` |
| `Foo::make()` | `make()` |

An extension operator is a static `__kairo_op_<name>` (`__kairo_op_as_<result as an identifier>` for an `op as`) taking `X&` / `const X&`; its receiver is the object (`a == b` is the operator called on `a` and `b`; a non-const operator on a prvalue materializes it). A call through an interface bound becomes a witness call, and the pass records the witness on the call for EmitIR ([Witnesses.md](Witnesses.md#call-sites)).

### SequenceLowering

`SequenceLowering.k`. Kairo evaluates left to right: a call's receiver (operand zero) then its arguments as written, a binary operator's left operand then its right, a subscript's base then its index, an assignment's place then its value then the store, an initializer's fields as written. C++ does not promise this, and clang and gcc differ in practice, so the order is written into the tree. Every operand before the last effectful one that has an effect, or reads state an effect could change, is bound in order to a `__kairo_ordN` local inside a statement expression placed where the call sat, so short circuits and per-iteration evaluation are kept. Literals, eval constants, unaliased locals, `&x` and a cast of a name never need binding.

A call whose result is an lvalue (an imported `T&` return) or a record value keeps C++'s order: a statement expression yields a prvalue, which would change the category or force a copy the type may not have. The exception is a panic result held by PanicLowering, the one record result it sequences. Primitive operators are not calls and are not covered. An assignment's place is bound the same way (`({ auto&& __kairo_ord0 = (a[i()]); __kairo_ord0 = v(); })`); when the assignment is a whole statement and its type is a record, the store ends the block inside a block of its own, so the statement expression is void and C++ copies no result out of it (a move-only record has no copy: `**p = X()`, `v[i()] = X()`).

A receiver that is a record prvalue is bound to its own named local (`_extend_receiver_temp`). A call's result may point into that temporary (`make().first(1)` returning a pointer into it), so a call made on the block's result is moved into the block's tail (`({ B t = make(); B* p = t.first(1); p->note(..)->emit(); })`) instead of running after the block, and the temporary lives to the end of the original statement. The order is unchanged.

SequenceCheck runs next. No node C++ evaluates in an unspecified order may have two effectful operands (an ICE otherwise), and from here on a pass that mints one ICEs at the mint (`LowerSynth::_mint_check`). The passes after it mint only calls with at most one effectful operand.

### ListLiteralLowering

`ListLiteralLowering.k`. Renders each list literal as the construction X decided ([ExprTyping.md](ExprTyping.md#list-literals)):

| Literal | Lowered |
|---|---|
| `[T; N]` | `InitListExpr { a, b, c }` |
| Slice, FullExpr | `Slice(<array prvalue> as *T, N)` |
| Slice, Extended | `var __kairo_tmpK: [T; N] = { a, b, c };` spliced before the owning declaration, then `Slice(__kairo_tmpK as *T, N)` |
| Vector | `Vector(Slice(<array prvalue> as *T, N))` |
| Vector, empty | `Vector()` |
| Slice, empty | `Slice(&null, 0)` |

The array prvalue has the full-expression's lifetime in C++, which is what FullExpr means; no statement is hoisted for it. Both constructor arguments carry an explicit cast because the callee is the pattern's constructor, whose parameter types are dependent.

Where an Extended backing lives depends on where its owner is:

- A local `var`: a local `DeclStmt` spliced ahead of the owner's. For a `static` or `thread` local the backing takes the same storage, so it is built once with the owner and outlives the frame like the owner does.
- A namespace-scope variable (a file-scope `var` or `const`, or one in a `module` block): a namespace-scope variable in the owner's scope, spliced ahead of the owner (into a TU's item list, or a module's decl list) and named after it, `__kairo_slice_<owner>_K`. C++ initializes namespace-scope variables in definition order within a TU, so the backing is set before the owner reads it, and it lives as long as the owner. The owner's name is unique in its namespace, which several files of one module can share, so a bare per-file counter could repeat there and fail to link.
- A script's deferred binding ([ScriptMode.md](ScriptMode.md#desugaring)): ScriptLowering has already moved the initializer into the synthesized `main` as `g = <init>`, an expression statement at main's top level, carrying its Extended mark. The backing is a local of `main` spliced ahead of that statement. It is built at the binding's line and outlives every read of `g`, because main's teardown `finally` nulls `g` on the way out.

A for-init is the one slot with no statement list. An Extended literal there is an ICE that says so.

### StringLowering

`StringLowering.k`. Every literal typed `string` becomes the borrowed constructor X bound (`string_ctor`): `"hi"` is `string("hi" as unsafe *const u8, 2, 2)` (bytes, `len` in bytes, `cp_len` in codepoints, `cap` 0 as the borrow flag). Escapes are decoded here, once, into UTF-8, and adjacent parts concatenated. The decoder is the lexer's (`Immediate::decode_escapes`, through `string_chain_bytes`), and the chain of adjacent segments is read, never changed: the segments are the lexer's, and the same literal is lowered again from every expansion of a macro whose body or argument writes it. A literal C++ reads at compile time (`StringLiteralExpr::const_eval`, [Eval.md](Eval.md#codegen)) passes its bytes uncast. A literal marked as a C string argument (`c_string`) becomes the bytes alone. FStringLowering ran first; an f-string reaching this pass is an ICE.

A byte string is not typed `string` and is lowered on its own: `b"ab\xff"` -> `Slice("ab\377" as unsafe *const u8, 3)`, typed `[const u8;]`: the minted byte literal, cast, and its length. No `string` is built.

### PurityInference

`FnPurityCheck::infer` (`Compiler/Sema/Check/FnPurityCheck.k`), under `-finfer-purity`, on by default (`-fno-infer-purity` turns it off; it changes the emitted C++). It lowers nothing. For every function of the TU that made no promise and could carry one (not virtual, polymorphic, a requirement, FFI, generic or in a generic, `main`, a generator, `async`, `eval`, `-> !`, `void`, a function with a panic set, one a lowering minted; an `@unwind` one fails the rules), it runs FnPurityCheck's rules silently as a greatest fixpoint over the call graph: every candidate starts at const, a candidate that breaks the const rules falls to pure, one that breaks those falls to none, until a round changes nothing. A node kind the rules do not model (a closure, a panic slot, anything a lowering left that is not on the list in `visit_expr` / `visit_stmt`) makes the function impure. The verdict is `FunctionDecl::inferred_purity`, stamped on every link of the chain; `Speller::fn_attrs` spells it like a written promise on declarations and definitions alike, which is the cross-TU point: an importer's declaration carries `[[gnu::const]]` without LTO. A callee counts with its verdict once its TU's Sema has run (rests run in import order); in an import cycle a callee whose TU comes later counts as impure. ParamPassInference skips a const function, written or inferred: `[[gnu::const]]` is memory(none), and a `const T&` parameter is memory. A C/C++ callee counts when clang itself marks it const (or, for @pure, const or pure): [SemanticChecks.md](SemanticChecks.md#fnpuritycheck). `--print-stats` prints the build's inferred counts.

### ParamPassInference

`Compiler/Sema/Check/ParamPassInference.k`. It lowers nothing. Over the finished tree it decides which by-value parameters their function never mutates ("never mutated" is a whitelist of read uses), stamps `ParamDecl::inferred_const` on every link of the redeclaration chain, and warns SC224W "parameter 'x' is never mutated; declare it 'const'" with a `const ` fix-it, in user files only. The file's header holds the mutation rule and the aliasing caveat. It runs after every lowering so a use a lowering mints (a move, a user operator's method call, an iterator call) is seen. A const function (written, or inferred by PurityInference) keeps its parameters by value. Nothing in Sema reads the flag, so every TU's flags are final before any TU's codegen. The ownership rationale is in [Ownership.md](Ownership.md#copy-and-move); the C++ spelling in [Codegen.md](Codegen.md#speller). Under `-Wconst-self` (opt-in) the same walk is also the const-self lint, SC273W / SC274W ([SemanticChecks.md](SemanticChecks.md#const-self-lint--wconst-self)).

Eligible parameters are named, non-pack and by-value (not `self`, not already `const`), of a concrete Kairo record of COPY category whose `trivially_copyable` is No (a string, a vector, a map, a class with a copy constructor). An imported C++ record keeps its value, as do scalars, pointers, `fn` values, any trivially copyable record (a register pair or a memcpy beats the indirection at small sizes, and Sema has no record layout yet for a size threshold), and a MOVE record (taking ownership is the parameter's point).

Never inferred, because something else fixes the signature: `virtual` / `override` / abstract methods and every method of a class with a polymorphic base (C++ would hide the base's slot); interface members; `ffi "c"` / `ffi "c++"` linkage and calling conventions; generic functions and members of generic records or extensions (the pattern alone would decide a fact every instance shares); generators and `async` functions (the frame outlives the call); `-> !` and `@cold_path` functions (the copy is paid at most once on the cold edge); split and transfer constructors; `where` groups; allocator operators; ADT members; `eval` functions; `main`; every compiler-made function.

## Union-storage locals

`x.finally()` (and `x.op finally()`) runs the destructor of the automatic local `x` where it is written, and the scope's end does not run it again. C++ runs a local's destructor at every exit on its own, so a local some site ends early is not a C++ local of type `T`: it is the member of a union whose destructor does nothing, and its mode says what runs the destructor. The mode is `VariableDecl::dtor_mode` (`LocalDtor`), written in `Sema/Check/LocalDisposition.k` and read by EmitIR alone:

| Mode | When | Emitted (`T x = init`) |
|---|---|---|
| `Scope` | nothing ends the local early (every local by default) | `T x = init;` |
| `Cleanup` | union storage with nothing ending it (`-funion-locals=all` only) | `::__kairo_ul<T> __k_s_x{init}; __attribute__((cleanup(__kairo_ul_run))) ::__kairo_ulh __k_h_x{&__k_s_x, &::__kairo_ul<T>::__drop};` |
| `Elided` | every exit of the scope is reached only after a site that ended it | `::__kairo_ul<T> __k_s_x{init};` |
| `Flagged` | some exits are reached with it ended and some with it alive, or the function can unwind | `::__kairo_ulf<T> __k_s_x{{init}, true}; __attribute__((cleanup(__kairo_ul_run))) ::__kairo_ulh __k_h_x{&__k_s_x, &::__kairo_ulf<T>::__drop};` |

Every use of `x` is the member itself, `__k_s_x.v` (flagged: `__k_s_x.s.v`), never a reference to it, so `decltype` of the use is `T`, and `sizeof`, `alignof` and the address are a plain `T x`'s (the member is at offset 0). `x.finally()` is `__k_s_x.__end()`: the member's destructor, and, flagged, `live = false` first. A `const` local is `__kairo_ul<const T>`. The storage and hook are named from the local's C++ name, so a shadowing local (`VariableDecl::rebind`, [Codegen.md](Codegen.md#shadowing-locals)) is `__k_s___kairo_rebind<n>_x` beside the `__k_s_x` it hides.

The helpers are written once per C++ TU when a body has such a local (`EmitPlan::needs_union_local`, `InterfaceEmitter::_union_local_helpers`, guarded in a header):

- `__kairo_ul<T>` has no constructor, so it is an aggregate: `__kairo_ul<T> s{init}` copy-initializes the member exactly as `T x = init` does, a prvalue built in place, so a type that can be neither copied nor moved still works. A forwarding constructor would bind a prvalue to a reference and move from the temporary. `{}` for `var x: T` value-initializes as `T x{}` does.
- The cleanup attribute names `__kairo_ul_run`, the one non-template function: clang accepts a template-id there but never instantiates it (the link fails), and rejects a qualified name, so the hook `__kairo_ulh` carries the object's address and the type's `__drop`. It is declared after the object, so it is armed only once the object is built: a path that leaves while the initializer runs (a statement expression's propagation) destroys nothing. At `-O2` the hook folds away: an elided local compiles to the destructor's body at the `finally()`, with no flag and no branch.
- `__attribute__((cleanup))` is a GNU extension clang supports on every target Kairo builds for (the Windows targets are `*-windows-gnu`). It runs on a normal exit, on an unwind, and when a coroutine frame is destroyed.

Which mode. MoveCheck walks every exit of each block (fallthrough, `return`, `break`, `continue`, a panic leaving it, and in a generator each `yield`, where the frame may be destroyed) after the block's pending `finally { }` bodies, with the set of locals ended on EVERY path there (`MoveState::ended`, joined by intersection). A local some `finally()` ends is `Elided` when no exit of its scope is reached with it outside that set, else `Flagged`. A function that can unwind (`FunctionDecl::no_unwind` false: `@unwind`, `-funwind`), a closure body under `-funwind`, and a local declared inside a `try` with a C++ exception arm have exits the walk does not see, so there it is always `Flagged`. (MoveCheck reads an arm whose filter is an imported C++ record as a C++ exception arm itself: PanicEffectChecking marks `is_cxx` only after it.)

What the checker reports (MoveCheck, `_finally_call`): a use after `finally()` on any path, a write to a part of the local included (SC303E, the same path analysis as use after move, a `MoveKind::Finalize` part); a second `finally()` on a path (SC304E); `finally()` on anything but a local the body declares: a parameter, `self`, a field, a global, a static, a temporary, a local of an enclosing body seen from a closure (SC305E); on a trivially destroyed local, nothing (SC305W). Not supported yet (SC116E): a fixed-size array, a local of an `eval fn`, a C-style `for`'s variable, and a call inside a `finally { }` block. `finally()` on a moved-from local is accepted: the moved-from object is destroyed there instead of at the scope's end. A stored call result's link over a part of `x` (`CondLink`) is dropped at the `finally()`: no outcome of the call says anything about an object that is gone. An ended local and a link are independent facts, joined separately (`ended` by intersection, links when both sides hold the same one).
Re-construction. A whole assignment of a new value to a finalized local, `x = T(...)` or any `x = e` of the whole object, revives it as an assignment revives a moved-from local (MoveCheck, at the same `clear`), but the storage holds no object, so it is a construction: `e` is built in place as `T x = e` would build it, and neither the old value's destructor nor an assignment runs. The local is usable again, the scope's end destroys it again unless another `finally()` ends it, and a second `finally()` after it is legal. MoveCheck records on the assignment the states it is reached in (`AssignOperatorExpr::remake`: `REMAKE_LIVE`, `REMAKE_DEAD`, `REMAKE_MAYBE`); OperatorLowering lowers no `op =` for one reached dead. EmitIR writes, reached dead only, `(::new (static_cast<void*>(&__k_s_x.v), ::__kairo_ulp{}) decltype(__k_s_x.v)(e), void())` (flagged: `__k_s_x.s.v`, then `live = true`). Reached maybe dead, or dead on one visit and alive on another (a loop), the local takes the flag and the assignment first runs `__k_s_x.__kill()`, which destroys the object only if `live` says one is there. `__kairo_ulp` is the preamble's placement tag with its own `operator new`, so no `<new>` is needed. Use before the re-construction is still SC303E, two `finally()` with none between still SC304E, and a use after an `if` that re-constructed on one branch only is SC303E (maybe finalized).
Generic locals. `finally()` on a local whose type is a generic parameter, or depends on one, is accepted and decided per instance: the body is one C++ template, `__kairo_ul<T>` is valid for every T, an instance with a destructor runs it, and a trivially destroyed T runs nothing (the preamble's `__kairo_ul_kill` takes an array too, last element first). No SC305W is given in a generic body. The use-after and finalized-twice checks are the body's, type-independent. An array T passed by value is rejected before this (arrays are not copyable).

A move out of a union local is unchanged (`static_cast<T&&>(__k_s_x.v)`), and the moved-from object is still destroyed by the cleanup. A `return x` of a union local is spelled `return static_cast<decltype(__k_s_x.v)&&>(__k_s_x.v);`: C++ moves only a returned name on its own. It cannot be elided (NRVO), so the moved-from object is destroyed at the return. A closure capture copies or moves out of the member (`[x = __k_s_x.v]`), and inside the closure `x` is its own copy.

EmitIR keeps the plain `T x` for a `Cleanup` local whose declaration cannot take the storage (a C-style `for`'s variable, an `@align` local, a hidden member type, a split constructor's carried local) and ICEs for an `Elided` or `Flagged` one, and for an `Elided` or `Flagged` local no written site ended: the mode and its sites come from one place.

`-funion-locals=all|finally` (hidden; `finally` is the default) gives `Cleanup` storage to every block-scope local with a non-trivial destructor that nothing ends, which behaves as `T x` except that a returned local is not elided. It exists to measure that storage on the whole tree.

### Disarmed moves

The same storage lets a move end a local's lifetime: a local that is definitely moved need not have its moved-from object destroyed. The analysis that proves "definitely moved" is not part of the compiler; what exists is the plumbing a provider of it calls:

- MoveCheck records, for every move, what kind it is (`MovedPart::kind`, `MoveKind`). Only `Transfer`, a Kairo move construction, move assignment or return of the value into the SAME type through a slot whose declaration is known (a variable, an assignment, a by-value parameter, a function's return), moves the object out. A converting constructor or `op =` may take the source by reference, so a move into another type is not recorded as real, and neither is a move into a struct literal's field (no slot type is passed there yet). A `@move` parameter, a C++ `T&&` parameter or forwarding pack, a parameter no declaration names (`UnknownParam`), a body that cannot be read, a C++ body moving out through a `T&` / `T*`, a callee's `move_out` record and a closure capture all leave the object, or a reference to it, behind. A real transfer of a whole local is recorded (`SemaContext::real_moves`) and answered by `is_real_transfer(sc, site, x)`.
- A provider calls `disarm_local_at(sc, site, x, mode)`, with `mode` `Elided` or `Flagged` as it proved for `x`'s exits. It records the site (`SemaContext::disarm_sites`) and joins the mode into `x`'s (`join_local_dtor`: Flagged over Elided over Cleanup over Scope), so two providers never weaken each other. It ICEs on a site that is not a real transfer of the whole local. Providers run after MoveCheck, which writes every local's mode afresh on each check.
- CopyMoveLowering puts the mark on the cast it makes at the site (`TypeCastExpr::disarms`). EmitIR does there what it does after `finally()` minus the destructor call: flagged, `(__k_s_x.live = false, static_cast<T&&>(__k_s_x.s.v))`; elided, the plain cast.

With no provider no move is disarmed. `--test-disarm-moved-locals` (hidden) is a test provider, not the feature (`Sema/Check/TestDisarm.k`): it disarms a local whose one move is a real transfer in straight-line code at the top level of its block (no branch, loop, `try`, `match`, jump or `panic` after the declaration, the move not under `&&` / `||` or an `if` / `match` / `try` expression or a closure, and nothing naming the local after it), and takes the mode from the same exit check as `finally()`.

## Monomorphization

M1 and M2 follow the lowerings in each TU's pipeline; they are specified in [Generics.md](Generics.md#monomorphization-sync-point).
