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

Rows 1 to 27 are also `LowerStep` (`Compiler/Sema/Lower/LowerStep.k`), whose declaration order is this order. Each of those passes starts its `run()` with `SemaContext::begin_lower(<its step>)`, which in a debug build ICEs unless the step just before it is the last one that started, and `_stage_lowerings` closes the list with `end_lowerings` after StringLowering. A pass moved, added or dropped without moving its step is an ICE at that pass, so the position constraints below are checked, not only stated. Rows 28 to 30 are not tree rewrites and keep their own gates.

| # | Pass | Position constraint | Specified in |
|---|---|---|---|
| 1 | VariantInitLowering | first: X's variant facts are on the nodes X wrote them on, and every later pass sees one node kind for a construction | [Passes](#variantinitlowering) |
| 2 | EnumLayoutLowering | before every body rewrite: every later pass reads ADT values through the layout record's query surface | [Passes](#enumlayoutlowering) |
| 3 | ExprBodyDesugar | every later pass sees a block body (SequenceLowering hoists into statements) | [Passes](#exprbodydesugar) |
| 4 | WhereDispatchLowering | after ExprBodyDesugar; before every other body rewrite and before CopyMoveLowering | [Passes](#wheredispatchlowering) |
| 5 | FieldInitLowering | clang takes no statement expression at class scope; later passes meet the initializer as a `return` | [Passes](#fieldinitlowering) |
| 6 | CtorInitLowering | before any pass inserts a statement: the cut is a statement count | [Passes](#ctorinitlowering) |
| 7 | CopyMoveLowering (moves) | before any pass rebuilds an expression | [Ownership.md](Ownership.md#copy-and-move) |
| 8 | ScriptLowering | after CopyMoveLowering; before FinallyLowering and the nullable block | [ScriptMode.md](ScriptMode.md#desugaring) |
| 9 | PanicLowering | after ScriptLowering and CopyMoveLowering; before FinallyLowering, LabelLowering, CallLowering, SequenceLowering | [Panic.md](Panic.md#passes) |
| 10 | FinallyLowering | after CopyMoveLowering and PanicLowering; before every other body rewrite | [Passes](#finallylowering) |
| 11 | TupleLowering | after CopyMoveLowering; before OperatorLowering (an operator on `t.0` sees a field path) | [Passes](#tuplelowering) |
| 12 | CoalesceLowering | nullable block, step 1 | [Nullables.md](Nullables.md#passes) |
| 13 | NullTestLowering | nullable block, step 2 | [Nullables.md](Nullables.md#passes) |
| 14 | NarrowedAccessLowering | nullable block, step 3 | [Nullables.md](Nullables.md#passes) |
| 15 | NullableTypeLowering | nullable block, last; after CopyMoveLowering; before OperatorLowering | [Nullables.md](Nullables.md#passes) |
| 16 | OperatorLowering | after the nullable block (`===`'s `==` may be a user operator) | [Passes](#operatorlowering) |
| 17 | FStringLowering | after OperatorLowering (a hole may hold a user operator); before StringLowering | [FormatStrings.md](FormatStrings.md#lowering) |
| 18 | CallLowering | before SequenceLowering: a default thunk's call is an impure argument | [Passes](#calllowering) |
| 19 | IterLowering | before ExtensionLowering (an extension `op in` is called through a chain), SequenceLowering and ListLiteralLowering | [Passes](#iterlowering) |
| 20 | RangeLowering | after IterLowering, which consumes loop ranges, and OperatorLowering | [Passes](#rangelowering) |
| 21 | MatchLowering | after IterLowering and RangeLowering; before SequenceLowering and StringLowering | [Passes](#matchlowering) |
| 22 | LabelLowering | after IterLowering (labels on minted loops) and MatchLowering (an arm's `break L` moves with the arm) | [Passes](#labellowering) |
| 23 | ExtensionLowering | before SequenceLowering, which orders the receiver | [Passes](#extensionlowering) |
| 24 | SequenceLowering | after OperatorLowering (operators are calls); before ListLiteralLowering | [Passes](#sequencelowering) |
| 25 | SequenceCheck | right after SequenceLowering; from the next step on `SemaContext::sequenced()` is true | [Passes](#sequencelowering) |
| 26 | ListLiteralLowering | after OperatorLowering and SequenceLowering | [Passes](#listliterallowering) |
| 27 | StringLowering | last rewrite: a literal is pure until it becomes a constructor call | [Passes](#stringlowering) |
| 28 | PurityInference (-finfer-purity, on by default) | after every lowering (judges every call a lowering minted); before ParamPassInference, which must leave an inferred-const function's parameters by value | [Passes](#purityinference) |
| 29 | ParamPassInference | after every lowering: reads the tree EmitIR renders | [Passes](#parampassinference) |
| 30 | EnumLayoutSweep | after every lowering: instances a lowering minted are in the registry | [Passes](#enumlayoutlowering) |

`PurityInference` is `FnPurityCheck::infer` and `ParamPassInference` lives in `Compiler/Sema/Check/`; `SequenceCheck` in `SequenceLowering.k`; the sweep is `EnumLayoutQuery::sweep`. A `using Base::name;` for merged base overloads is not a pass: InterfaceEmitter writes it where the class is spelled ([MemberLookup.md](MemberLookup.md#inheritance)).

Not implemented:

- `TypeQueryLowering.k` is a stub; `sizeof` / `alignof` emit as C++ `sizeof`, and `typeof` as a value has no lowering.
- CopyMoveLowering's copy half ([Ownership.md](Ownership.md#copy-and-move)).
- Context bindings: EmitIR ICEs on a `ContextBindingStmt`, naming a ContextLowering that does not exist.

## Passes

Passes specified in another document have only their row above.

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

`WhereDispatchLowering.k`. Each group in `where_groups` becomes one function. The lead keeps its identity (every call names it) and becomes the dispatcher, with fresh parameters: `if g0 { return K0(args) } ... return Kn(args)`, guards in dispatch order, each retargeted by position to the fresh parameters, the last call untested. Every member hands its parameters and body to a minted `priv` candidate `__kairo_where_<name>_<k>` (k in source order, `LowerTargets`), so no body is rewritten; a non-lead member leaves the tree. A forwarded by-value MOVE parameter is recorded in `move_sites` for CopyMoveLowering.

### FieldInitLowering

`FieldInitLowering.k`. A class or struct field's initializer becomes its C++ default member initializer.

- A constant (an integer ConstEval folds that fits the field, `true` / `false` on a bool, `&null` on a raw pointer) is recorded on the field (`FieldDecl::init_fold`, the value in `init_neg` / `init_mag`) and spelled in the class.
- Anything else becomes `fn __kairo_init_<f>(self) -> T { return <init> }` (`LowerTargets::field_init_thunk`), appended to the record's methods and stamped as `FieldDecl::init_thunk`; the default calls it. The thunk is a method, so a bare member the initializer names is read through `this` (InitCheck guarantees that member is built first). Its body goes out of line like every user body ([Pipeline.md](Pipeline.md#invariants)).
- A static field folds or thunks the same way; its thunk takes no `self`, and the value is its out-of-line definition's ([Codegen.md](Codegen.md#interfaceemitter)).
- An array field's list literal is lowered one element at a time, since no C++ function returns an array: a thunk per element, `__kairo_init<i>_<f>` (`LowerTargets::field_init_elem_thunk`), stamped in order as `FieldDecl::init_elems` (`init_fold` Elems); the default is `= {__kairo_init0_f(), ...}`.

`init` is null afterwards (moved into the thunk). Eval fields and every other array initializer keep `init`; FeatureGateCheck rejected them.

### CtorInitLowering

`CtorInitLowering.k`. A constructor that CtorInitCheck split has its body cut into exactly two blocks, `{ {S_pre} {S_post} }`, at `ci_split`, and `ci_cut` set. Nothing is renamed or minted, so Sema's view of the record is unchanged. It runs right after FieldInitLowering because the cut is a statement count: every later pass may insert statements, and each lands inside its own half.

### FinallyLowering

`FinallyLowering.k`. `finally { body }` becomes a StructDecl declared in the function body whose `op finally` is the body, plus a local of it where the statement stood (`__kairo_FinK` / `__kairo_finK`, LangItems). C++'s rule for locals is the language's `finally`: destroyed at the block's end, on every exit, LIFO with the block's other locals. Captures (FreeVarScan, `CaptureAnalysis.k`) are the free automatic locals and the enclosing function's parameters, each by address, in first-use order; the enclosing `self` is the `__kairo_owner` pointer field. Each use in the body is rewritten to `(*self.<field>)`. Statics and globals are not captured. EmitIR emits the record in place (`_local_record`), CXXSpell names a function-scope record by its leaf, and EmitPlan never admits one. A `finally` in a closure is the same record declared in the lambda's body and homed in the enclosing function; the closure's parameters are captured like a function's, and a binding the closure holds by pointer is reached through that pointer.

The explicit destructor call `x.finally()` is a call of that same `op finally` and reaches C++ as `x.~T()`; `@cxx::new` / `@cxx::delete` (and their array forms) lower to the plain C++ `new` / `new[]` / `delete` / `delete[]` expressions, with the constructor chosen by the ordinary overload resolution, and are never routed through `create` / `destroy` ([Ownership](Ownership.md#destruction-and-freeing)).

### TupleLowering

`TupleLowering.k`. A tuple is its arity's record: `(A, B)` is `Tuple2<A, B>`, a generic struct with fields `_0: T0, _1: T1`, no constructor and no methods, minted on first use (`AST/Context/TupleRecords`, one per arity per build, homed in the builtin root TU, in no table) and canonicalized by T through `SemaContext::tuple_record`, the one builder, so a written tuple, a literal's and a substitution's share one identity and one registry entry. No canonical is a TupleType after T. `TypeUtil::is_tuple` / `tuple_elems` / `tuple_field` key on `StructDecl::tuple_arity` of the pattern, never the name (`LangItems::tuple_record_name` is the only speller). X binds `t.1` to the field `_1` (an lvalue).

The pass rewrites:

- a literal into the record's NamedInitializerExpr (fields in element order);
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
| `x as T` with `op as` | `x.op as()`; a converting constructor becomes the construction |
| `x ^^ n` | `pow(x, n)` (the lang item) |
| `a != b` from `op ==` | `!(a.op==(b))` |
| `a < b` from `op <=>` | `((a.op<=>(b)) as i8) < 0` |
| `a == b` on an ADT (`tag_eq`) | variant comparison through `EnumLayoutQuery::same_variant` |
| `a += b` with `op +=` | `a.op+=(b)` |
| `a += b` with only `op +` | `a = a.op+(b)`, `a` evaluated once |

It also expands the checked casts X marked: `enum_check` into a range or per-variant test that crashes through UnwrapFailed, and `asserting_downcast` into a dynamic cast that crashes on a non-null miss ([ExprTyping.md](ExprTyping.md#expression-typing), Casts). `a[i..j]` on an array wraps the base in an `ImplicitBoundaryCastExpr`.

### CallLowering

`CallLowering.k`. After it every call has one positional argument list in parameter order; `NamedArgExpr` is gone and `arg_map` is empty.

- A default becomes a nullary thunk (`LowerTargets::default_thunk`), one per entity and parameter index, stamped as `ParamDecl::default_thunk` at that index on every link of the redeclaration chain and spliced beside the declaring link; a default written on an out-of-line definition becomes a member of the owner. `default_val` is moved into the thunk.
- Explicit arguments evaluate left to right as written, whatever parameter they name; defaults evaluate after them, in parameter order.
- A pack over one type is a `Slice<E>` by value (`ParamDecl::pack_type`) over a backing array alive for the call's full-expression. A type pack (`fn <...T> f(...xs: T)`, `param_is_type_pack`) is a C++ parameter pack, its run left one argument per element. An imported pack (`Args&&... args`) is one too: its element is the expansion's pattern, which may be a reference to the pack.
- Dependent calls are left as written.

### IterLowering

`IterLowering.k`. X records each ranged `for`'s `iter_kind`, `iter_elem` and, for a user `op in`, `iter_op` and `iter_inst` (a generic one's instance; an extension's on `[T]` is called with X's arguments, never clang's). The pass renders a block of hidden locals and a `while` that advances before its body, so `continue` needs no step.

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

An extension operator is a static `__kairo_op_<name>` taking `X&` / `const X&`; its receiver is the object (`a == b` is the operator called on `a` and `b`; a non-const operator on a prvalue materializes it). A call through an interface bound becomes a witness call, and the pass records the witness on the call for EmitIR ([Witnesses.md](Witnesses.md#call-sites)).

### SequenceLowering

`SequenceLowering.k`. Kairo evaluates left to right: a call's receiver (operand zero) then its arguments as written, a binary operator's left operand then its right, a subscript's base then its index, an assignment's place then its value then the store, an initializer's fields as written. C++ does not promise this, and clang and gcc differ in practice, so the order is written into the tree. Every operand before the last effectful one that has an effect, or reads state an effect could change, is bound in order to a `__kairo_ordN` local inside a statement expression placed where the call sat, so short circuits and per-iteration evaluation are kept. Literals, eval constants, unaliased locals, `&x` and a cast of a name never need binding.

A call whose result is an lvalue (an imported `T&` return) or a record value keeps C++'s order: a statement expression yields a prvalue, which would change the category or force a copy the type may not have. The exception is a panic result held by PanicLowering, the one record result it sequences. Primitive operators are not calls and are not covered.

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

### StringLowering

`StringLowering.k`. Every literal typed `string` becomes the borrowed constructor X bound (`string_ctor`): `"hi"` is `string("hi" as unsafe *const u8, 2, 2)` (bytes, `len` in bytes, `cp_len` in codepoints, `cap` 0 as the borrow flag). Escapes are decoded here, once, into UTF-8, and adjacent parts concatenated. A literal C++ reads at compile time (`StringLiteralExpr::const_eval`, [Eval.md](Eval.md#codegen)) passes its bytes uncast. A literal marked as a C string argument (`c_string`) becomes the bytes alone. FStringLowering ran first; an f-string reaching this pass is an ICE.

### PurityInference

`FnPurityCheck::infer` (`Compiler/Sema/Check/FnPurityCheck.k`), under `-finfer-purity`, on by default (`-fno-infer-purity` turns it off; it changes the emitted C++). It lowers nothing. For every function of the TU that made no promise and could carry one (not virtual, polymorphic, a requirement, FFI, generic or in a generic, `main`, a generator, `async`, `eval`, `-> !`, `void`, a function with a panic set, one a lowering minted; an `@unwind` one fails the rules), it runs FnPurityCheck's rules silently as a greatest fixpoint over the call graph: every candidate starts at const, a candidate that breaks the const rules falls to pure, one that breaks those falls to none, until a round changes nothing. A node kind the rules do not model (a closure, a panic slot, anything a lowering left that is not on the list in `visit_expr` / `visit_stmt`) makes the function impure. The verdict is `FunctionDecl::inferred_purity`, stamped on every link of the chain; `CXXSpell::fn_attrs` spells it like a written promise on declarations and definitions alike, which is the cross-TU point: an importer's declaration carries `[[gnu::const]]` without LTO. A callee counts with its verdict once its TU's Sema has run (rests run in import order); in an import cycle a callee whose TU comes later counts as impure. ParamPassInference skips a const function, written or inferred: `[[gnu::const]]` is memory(none), and a `const T&` parameter is memory. A C/C++ callee counts when clang itself marks it const (or, for @pure, const or pure): [SemanticChecks.md](SemanticChecks.md#fnpuritycheck). `--print-stats` prints the build's inferred counts.

### ParamPassInference

`Compiler/Sema/Check/ParamPassInference.k`. It lowers nothing. Over the finished tree it decides which by-value parameters their function never mutates ("never mutated" is a whitelist of read uses), stamps `ParamDecl::inferred_const` on every link of the redeclaration chain, and warns SC224W "parameter 'x' is never mutated; declare it 'const'" with a `const ` fix-it, in user files only. The file's header holds the mutation rule and the aliasing caveat. It runs after every lowering so a use a lowering mints (a move, a user operator's method call, an iterator call) is seen. A const function (written, or inferred by PurityInference) keeps its parameters by value. Nothing in Sema reads the flag, so every TU's flags are final before any TU's codegen. The ownership rationale is in [Ownership.md](Ownership.md#copy-and-move); the C++ spelling in [Codegen.md](Codegen.md#cxxspell). Under `-Wconst-self` (opt-in) the same walk is also the const-self lint, SC273W / SC274W ([SemanticChecks.md](SemanticChecks.md#const-self-lint--wconst-self)).

Eligible parameters are named, non-pack and by-value (not `self`, not already `const`), of a concrete Kairo record of COPY category whose `trivially_copyable` is No (a string, a vector, a map, a class with a copy constructor). An imported C++ record keeps its value, as do scalars, pointers, `fn` values, any trivially copyable record (a register pair or a memcpy beats the indirection at small sizes, and Sema has no record layout yet for a size threshold), and a MOVE record (taking ownership is the parameter's point).

Never inferred, because something else fixes the signature: `virtual` / `override` / abstract methods and every method of a class with a polymorphic base (C++ would hide the base's slot); interface members; `ffi "c"` / `ffi "c++"` linkage and calling conventions; generic functions and members of generic records or extensions (the pattern alone would decide a fact every instance shares); generators and `async` functions (the frame outlives the call); `-> !` and `@cold_path` functions (the copy is paid at most once on the cold edge); split and transfer constructors; `where` groups; allocator operators; ADT members; `eval` functions; `main`; every compiler-made function.

## Monomorphization

M1 and M2 follow the lowerings in each TU's pipeline; they are specified in [Generics.md](Generics.md#monomorphization-sync-point).
