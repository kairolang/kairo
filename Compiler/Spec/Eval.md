# Compile-time evaluation

`eval` from parse to C++. The language rules (what may be `eval`, the restriction table, eval classes) are in the website reference (eval); this document covers how the compiler implements them. The slots of the passes below are [Pipeline.md](Pipeline.md#sema-pass-order).

| File | Role |
|---|---|
| `Compiler/Sema/Expand/EvalIfFolding.k` | `eval if` folding (phase E) and late folding (`run_late`) |
| `Compiler/Sema/Expand/EvalBranches.k` | `EvalBranchTable`: the declarations of deferred `eval if`s, by branch |
| `Compiler/Sema/Check/EvalUsageChecking.k` | what an eval context may contain; `eval for` rules; eval ordering cycles |
| `Compiler/Sema/Check/ConstEval.k` | the integer engine |
| `Compiler/Sema/Resolve/TypeResolve.k` | array extents and value arguments, value nodes |
| `Compiler/Codegen/EmitPlan.k`, `Compiler/Codegen/Emit/EmitIR.k`, `Compiler/Codegen/Emit/InterfaceEmitter.k` | emission |

Tests: `Tests/Sema/Eval/`, `Tests/Codegen/eval/`.

## Evaluation model

### C++ computes

Stage 1 has no Kairo interpreter: C++ computes every `eval` value.

- An `eval fn` (free function, method, constructor) emits as `consteval`.
- An `eval` binding emits as `constexpr`.
- `eval e` emits as an immediately invoked `consteval` lambda, `[&]() consteval { return (e); }()`.
- An `eval for` emits as a pack expansion over values C++ computes.
- An `eval if` is folded by Sema wherever its condition decides which declarations exist; elsewhere it is `if constexpr`.

Sema type-checks every eval construct and checks that it is evaluable ([EvalUsageChecking](#evalusagechecking)); clang computes it. A Kairo evaluator replacing C++ here is a post-self-hosting design and does not exist. An `eval` constant needs an initializer (SC185E). A static assert is likewise emitted as C++ `static_assert(cond, "msg")`, so a Kairo-only condition C++ cannot evaluate fails in clang (CL001E); the intended design has Kairo's evaluator decide it.

### What Sema folds

Sema computes a value only where Sema itself decides something from it:

| Consumer | Why Sema needs the value | Evaluator |
|---|---|---|
| a declaration-scope `eval if`, and a foldable one in a body | which declarations exist, before name resolution | `EvalIfFolding` (bool and integer, over ConstEval) |
| array extents `[T; N]` | type identity: `[i32; N]` is `[i32; 3]` | ConstEval from `TypeResolve::_resolve_array` |
| generic value arguments `Buf<N>` | instance identity | ConstEval, `ConstEval::value_node` |
| enum discriminants, pattern bounds | layout and exhaustiveness | ConstEval |

Floats, strings and aggregates are never folded by Sema: no consumer decides anything from them. ConstEval (`Compiler/Sema/Check/ConstEval.k`) evaluates integer literals, unary `-` `~` `+`, builtin `+ - * | & ^ << >>` (and `bitor` / `bitand` / `xor`), parentheses, `as` to an integer type, a `const` / `eval` name or eval field whose initializer evaluates, and, in a discriminant, an earlier variant of the same enum. Values are `IntConst` (sign-magnitude over `u64`, `overflow` past 65 bits); arithmetic is exact, except a shift typed at 64 bits or fewer, which is the run-time shift (`shift_in`); range checks happen at the end (`fits`). It diagnoses nothing: a failure leaves `bad` / `bad_why` / `bad_decl` for the caller.

`TypeResolve::_resolve_array` calls ConstEval in phase T, before ExprTyper, so only what folds untyped folds there: literals, eval names, `+ - * << >> | & ^`, unary `-`; not `~`, and not an `as` whose target is unresolved. A qualified name (`m::K`) is looked up through the frozen tables (`ConstEval::scope_path`), since ChainBinding has not bound it. After substitution, `ConstEval::value_node` folds a value node whose operands are all values, `/` and `%` included.

### Evaluable values

Every literal is eval-able. Their compile-time C++ form:

| Kairo | C++ constant |
|---|---|
| integers, floats, `bool`, `char` | the scalar |
| `[a, b, c]` as `[T; N]` | `T const N[3] = {a, b, c}` |
| `(a, b, c)` | `::builtin::TupleN<...>`, an aggregate |
| a string literal | `::builtin::string::string` over `::__kairo_estr<bytes...>` or a named array ([Strings at compile time](#strings-at-compile-time)) |
| vector `[T]`, set `{a, b}`, map `{k: v}`, an f-string | none: SC116E |

The builtin string's literal constructor and empty constructor are `constexpr inline` (`NameResolution::_literal_ctor_constexpr`, by the lang item), so a string built from compile-time bytes is a constant expression. Collections stay SC116E until their run-time forms compile; the compile-time form is to mirror whatever those become. f-strings allocate, so they stay SC116E.

### Generic value parameters

A value parameter is spelled `<eval N: T>` (`fn <eval N: i32>`, `class <eval N: usize>`). `<const N: T>` is an error with a fix-it rewriting `const` to `eval`. `GenericParamDecl::is_const_param` means "a value parameter"; a C++ non-type template parameter imported by DeclImport is one too. A value argument must be eval-able: a literal, an `eval` name, an expression of those. A `const` (non-eval) name is an error, with a fix-it adding `eval` at its declaration when it is in the user's code. Explicit generic arguments are bound into each candidate's deduction (`OverloadResolution::_bind_explicit`).

A value parameter's type is an integer, a plain enum (a C++ enumeration template parameter whose argument is a variant), or a structural eval class ([Eval classes](#eval-classes)); a non-structural class is SC183E and any other type (`bool`, a float) SC116E. A value parameter default `<eval N: usize = 4>` does not parse. A value argument inside an expression-position generic in a generic body (`Ring<N>()`) is R023E.

### Value nodes

A canonical value argument is a canonical `TypeExpr` with a `ValueOp` (`Literal`, `Decl`, `Call`, `Unary`, `Binary`, `Cast`, `Str`), interned on its fields and operand canonicals (`CanonicalTypeStore::value_expr`, `value_arg`, `value_str`). `FixedArrayType::extent_param` holds the extent of `[T; N]` under a value parameter (`array_of_param`), or of a computed extent (`[T; N + 1]`, `[i32; f(3)]`); a generic value argument is the same node. Identity is structural: `[i32; f(3)]` is the same type as `[i32; f(3)]` and not `[i32; 3]` even when `f(3) == 3`, as with C++ dependent expressions before instantiation (the user-facing statement is in the website's generics page). After substitution a node whose operands are all values folds, so `Buf<3>`'s `[T; N + 1]` is `[T; 4]`. A computed extent or argument is a non-deduced context. Instance identity is [Generics.md](Generics.md#instantiation-registry)'s.

- A call of a non-eval function in an extent or argument is SC192E with a fix-it adding `eval`; a `const` name there is SC192E too, since a `const` is not evaluated at compile time.
- A node Sema cannot even type stays SC116E.
- An `eval` constructor call (`Grid<Pt(2, 3)>`) is a `Call` node naming the class. An eval binding whose initializer is a closed constructor call over literals, strings or such calls is that call's node (`TypeResolve::_vx_through`), so `Widget<SMALL>` and `Widget<Config(4, "small")>` are one type and one C++ specialization when the fields are equal. A binding computed by an eval fn keeps its `Decl` node (identity is the name). A foreign, already-lowered initializer gives the same nodes (`_vx_lowered_string`, `_vx_ctor_owner`).
- A string literal has a value node (`ValueOp::Str`, keyed on its decoded bytes) only as an argument of a `Call` node.
- An instance over a computed value gets no explicit instantiation line (`Buf<twice(1)>` may be `Buf<2>`, and C++ rejects two).

The binding of an unrolled `eval for` is a value node, so it is usable as an extent or generic argument inside the loop. Inside an `eval fn` the loop is ordinary and the binding is not a constant.

### Eval classes

A class is an eval class when it has an `eval` constructor; there is no keyword. A struct with no constructors is an eval value when every field is. The emission and rules:

- an eval constructor is `consteval`; an `eval` binding of an eval class is a `constexpr` object. The same constructor builds run-time objects from constant arguments (an immediate invocation);
- a field default that is not a constant becomes a `constexpr` (inline) thunk in an eval class, so both the consteval constructor and a run-time one can run it (`FieldInitLowering`);
- `eval fn` methods are `consteval`. An eval binding is const (`VariableDecl::is_const` includes `Eval`), so an eval method on one takes `const self`; a regular method is not callable from an eval context;
- an `eval` field is a class constant, static: one value per class. Per-object compile-time state is a `var` set by the eval constructor;
- an eval constant or eval-fn local whose type has a user-written destructor is SC184E (a compile-time object is never destroyed).

An eval class may be a generic value parameter's type when it is structural (`_check_structural` / `_structural` in EvalUsageChecking): every field `pub` (an unmarked class field is private), none `mutable` or a pointer to mutable memory, field classes structural in turn, every constructor `eval`, no destructor. Otherwise SC183E names the first offender, through nested fields, with a note at it. Arguments are an eval binding (`Decl` node) or an eval constructor call (`Call` node, spelled `::m::Pt(2, 3)`); ChainBinding anchors such a parameter as a value of its class. The C++ template is ordered after the class and not forward-declared. The builtin string's private fields interfere with eval access and structural checks.

### Requires predicates

A `requires` value predicate (not a `T impl I` / `T derives B` conjunct) is an eval context. One that reads a run-time value is SC186E "requires expression is not compile-time evaluable" (label at the run-time part, note suggesting `where`; `_check_requires`). A function's predicates become `static_assert`s at the top of its body, once for a plain function and per instance for a generic one: a non-template function cannot carry a C++ requires-clause. A generic record's self-contained predicates (own parameters, literals, `sizeof` / `alignof`, builtin operators) go on its C++ template head as `requires`, so clang rejects a bad instance at its use. One naming an eval constant or function is not checked, because the head precedes every other declaration.

## Passes

### Folding eval if

`EvalIfFolding::run()` is the first pass of phase E. It runs after I, so an imported `eval` constant is reachable through the overlay, and before V and N, so no later pass sees an untaken branch (which may name what does not exist on this target). It cannot run at parse exit: clang's macro table for an `ffi` header's HeaderSet is joined only when Sema starts, and blocking a parse worker on a header build risks a pool deadlock.

```kairo
eval if WIDE { eval LINE = 64  fn f() {} } else { eval LINE = 128 }
->
eval LINE = 64
fn f() {}
```

Frozen tables are never mutated. The parser indexes every branch's declarations into the enclosing scope's table (`ASTParse::_index_eval_branches`), as if hoisted, with member tables and dc links. The fold builds a new frozen table for each scope it folded in (`_rebuild_table`), without the discarded declarations and with each class branch's `VariableDecl` replaced by its `FieldDecl`, and swaps it in (the TU's and its `module_self`'s together).

Where the taken branch goes:

| Position | Hoisting |
|---|---|
| file scope | its statements replace the item; a declaration other than a variable becomes a `Decl` item, as the parser would have made it |
| module body | its declarations replace the `EvalBlockDecl` in the module's dc_decls |
| class body | each `var` becomes a `FieldDecl` appended to `fields` (`_as_field`), each `fn` is appended to `methods` |
| function body | its statements are spliced into the enclosing block (a fold has no scope, as `#if` has none); an untaken branch's local fn or class leaves the function's dc_decls |

A condition folds (`_fold`) from literals, `!`, `&&`, `||`, comparisons, ConstEval's integer arithmetic, parentheses, an `eval` name looked up from the innermost scope through the frozen tables and the overlay (minus what this pass discarded) whose initializer folds, and `defined!`. A function-body local is in no frozen table, so a body `eval if` on a local eval constant does not fold.

A condition that does not fold is SC230E at declaration scope, at the sub-expression with ConstEval's reason; a `sizeof` condition gets a note naming `defined!(__LP64__)` and a function-body `eval if`. In a function body it stays and is C++ `if constexpr`, both branches resolved and typed and branch declarations branch-local; its condition must still be eval-able ([EvalUsageChecking](#evalusagechecking)). A dependent condition in a generic body is the same `if constexpr`, permanently: the generic body is checked once against its bounds, so a branch valid only for some `T` is an ordinary type error.

In a class branch, a binding with no type is SC231E (a field declares its type); a module or class branch statement that is not a declaration is SC231E. An `eval for` in a module or class body is SC116E (FeatureGateCheck). The decided rule for when it is enabled: the body declares once per pass, and a name declared in two passes is an error unless it is built from the loop value. A class branch's `var` is laid out after every other field. A generic hoisted out of a file-scope `eval if` is unknown to another file's `<` disambiguation.

### defined!

`defined!(NAME)` answers from the Kairo macro table and clang's. The preprocessor writes `true` / `false` for a Kairo macro or `-D`, and passes any other `defined!(NAME)` through raw (remembering the site so its rescan does not expand it again). The parser builds a `DefinedExpr`; `transform_defined_expr` answers it from the TU's HeaderSet preprocessor (`HeaderSet::macro_defined`, `isMacroDefined`) when the TU has `ffi` headers, else from the target's predefines (`BuiltinsSet::predefined`). The result is `bool`; `defined!(X) as i32` gives the integer. Platform tests use `defined!(__linux__)`. EmitIR ICEs on a `DefinedExpr`, which means EvalIfFolding did not run.

### Deferred conditions

`sizeof`, `alignof`, `is_trivially_copyable!(T)` and `is_trivially_destructible!(T)` (`TypeTraitExpr`; C++ spells `__is_trivially_copyable` / `__is_trivially_destructible`) need resolved types, which phase E does not have. EvalIfFolding classifies each declaration-scope condition: folds now, error now, or deferred. A failure anywhere is reported now; `false && <fact>` and `true || <fact>` still fold now; anything else touching a fact, directly or through an `eval` constant's initializer, waits. A condition naming a constant only a deferred branch declares waits with it.

A deferred `eval if` stays in place with every branch indexed, is marked `ConditionalStmt::eval_deferred`, and is filed in `sc->eval_branches` (`EvalBranchTable`, `Compiler/Sema/Expand/EvalBranches.k`). Its branches are walked now (a nested `eval if` that folds does, every `defined!` becomes its literal), and a class branch's `var` becomes its `FieldDecl` now so N can bind it. A deferred branch may not declare a type (SC231E): T resolves type names before the fold and canonicals cannot be rebound. Until the late fold, N, T and RedeclMerge see every branch; `EvalBranchTable::exclusive` tells N(a) (`_validate_cell` -> `_judge_group`) and R(a) (`_merge_cell`) that two declarations in different branches of one deferred `eval if` never coexist, so they are neither a redefinition nor one entity. `pending_in` / `in_pending` report which records and names still wait. A type parameter in a declaration-scope condition is SC132E, with SC132N naming the requires-selected partial to write instead. In a function body nothing is deferred: `if constexpr` lets clang decide with its own layouts.

`EvalIfFolding::run_late()` decides the deferred ones after types are resolved: [late eval-if folding](TypeResolution.md#late-eval-if-folding). Its agreement pin (`fold_pin`, a `static_assert` after each constant the fold read through a type fact) is specified there.

Known limits:

- a type that reads a branch constant (`[u8; W]`) is resolved before the fold decides which `W` exists; a type declared in a deferred branch is refused;
- a condition reading a fact directly, and a constant from another TU, are not pinned;
- `requires is_trivially_copyable!(T)` on a partial is undecided by `InstantiationRegistry::requires_holds`, so SC132N's advice works only for conditions it decides, such as `sizeof` of builtins;
- `offset_of`, `is_base_of`, `is_convertible`, `is_constructible` are not intrinsics: Sema has no oracle for them;
- V passes see both branches of a deferred `eval if`, so an untyped `var` in an untaken class branch is reported;
- an out-of-line `fn C::m` defining a method declared in two sibling branches is not handled specially by R(b).

### EvalUsageChecking

Runs in the checks after ExprTyper (it reads callee bindings and `iter_kind`). C++ computes every eval value, so a mistake left to it is a clang error on emitted text; this pass reports the ones Kairo can name, at the Kairo source. Each error has a label, a note at the offending callee or declaration, and a fix-it where one is obvious.

An eval context is an `eval fn` body, an `eval` binding's or field's initializer, an `eval e` operand, a function-body `eval if` condition, an `eval for` iterable, and a `requires` value predicate. In it:

| Rule | Code |
|---|---|
| a call only of an `eval fn`, eval constructor or eval operator (fix-it: `eval` on the callee when it is the user's); this also keeps IO out | SC189E |
| no mutable global, static or thread variable, and no non-eval global (a `const` global is initialized at run time); outside an eval fn, no run-time local | SC189E |
| an `eval fn` takes no pointer parameter | SC188E |
| no pointer operations (`&x`, `*p`, `->`), no pointer-typed or static / thread local in an eval fn | SC194E |
| no `await`, `spawn`, `panic` | SC194E |
| no local of a type with a user-written destructor | SC184E |
| an `eval fn` has no `where` clause | SC187E |
| a vector, set or map value, an f-string, or an eval fn parameter or return of those types | SC116E |
| a compile-time value where one is required | SC192E |

Eval-able: literals; `sizeof` / `alignof` / `typeof`; builtin operators and casts over eval-able operands; an `eval` variable or field; a generic value parameter; an enclosing `eval for`'s binding; a call of an `eval fn` with eval-able arguments. The pass marks every string literal C++ reads at compile time (`StringLiteralExpr::const_eval`): in eval contexts, in the arguments of an eval call from run-time code, and in an eval class's field defaults.

`eval for` rules: the iterable is a range with eval-able bounds, an eval-able array (an `eval` constant, a list literal of eval-able elements), or a call of an eval generator (`eval fn g() -> yield T`); anything else is SC190E, with a fix-it adding `eval` to a non-eval generator. It has one binding, no label and no C-style form (SC194E for the binding and a range missing a bound). A function-body `eval if` may test `impl` only on a generic parameter of the function or its class, and not `derives` (SC191E). A `return` with a value from inside it must be of a type the expansion's return slot can default-construct (a scalar, pointer or enum; `_check_return_slot`). An eval generator may be called only as an `eval for` iterable. Inside an `eval fn` an `eval for` is an ordinary loop (IterLowering), possibly over a parameter, and none of this applies.

Ordering (`_check_order`): an early eval item that needs its own declaring record complete (`sizeof`, a local, a member of it, or a record holding it by value) is SC195E, and an eval binding whose value reaches itself is SC196E, each with a note. Generic records are not checked, since their head is read per instance.

Not checked: closures inside an eval fn; recursion depth (clang's constexpr limits apply). A run-time call of an `eval fn` with non-constant arguments is accepted by Sema and rejected by clang.

## Codegen

### eval fn

`eval fn` emits `consteval`. `consteval` is implicitly inline, so the body is part of the interface: EmitPlan makes an eval fn's body visible as it does an `inline` one, or an importer could not evaluate it. A call from run-time code is an immediate invocation. `emit_tu` writes compile-time bodies first (foreign visible ones, the TU's own free ones, then records' eval and constexpr methods), because Kairo declarations have no order and a constant expression needs its callee defined. An eval constructor's three functions (the split for const fields included) are all `consteval` ([Codegen.md](Codegen.md#emitir)).

### eval bindings

| Position | C++ |
|---|---|
| namespace scope | `inline constexpr T const N = init;` in every TU that reads it (`EmitPlan::visible_eval_vars`: a preamble's foreign ones, a header's own, both for a kcc include); the interface also keeps `extern T const N;` |
| function body | `constexpr T n = init;` |
| class body | `static const T K;` in the class; `inline constexpr T const R::K = init;` after it |

After the compile-time bodies `emit_tu` writes every eval binding, foreign and own, dependencies first (`EmitPlan::_eval_vars`, which follows what each reads through eval fn bodies; `_place_eval_var`). A class-scope initializer that folds is spelled at the definition after the class; any other becomes a static consteval thunk, and EmitIR writes the definition right after the thunk's body. `Self::K` inside a generic class is spelled without the template arguments.

`[i32; K]` as a field of `K`'s own class, where `K` does not fold, is SC116E at the length (note at the constant, fix-it moving it with `pub` to module scope; `TypeResolve.k`): `K` is not a constant expression inside its own incomplete class in C++. A folding eval field is spelled as its value and is accepted in its own class. ConstEval folds eval fields like eval variables, so `[i32; Grid::W]` works anywhere.

### Early eval items

A declaration's type may compute from an eval item (`[i32; f(3)]` in a field, a signature or a namespace-scope binding; `Buf<twice(1)>`), and C++ evaluates it where the declaration stands. EmitPlan defines those items ahead of the declarations that use them; the ordering is [Codegen.md](Codegen.md#emitplan)'s.

### Strings at compile time

A literal C++ reads at compile time (`StringLiteralExpr::const_eval`) is spelled without the run-time `reinterpret_cast`, which is not a constant expression:

- up to 256 bytes (`LowerTargets::eval_str_inline_max`): `::__kairo_estr<b...>`, the variable template `template <unsigned char... C> inline constexpr unsigned char __kairo_estr[] = {C..., 0};` (`LowerTargets::eval_str`). Keyed on the bytes, it is one object in every TU and header, so an eval string's `data` is the same address everywhere, a header body naming it is no ODR hazard, and nothing has to be hoisted ahead of the bodies that name it. A per-TU `static` array would have none of these properties;
- longer: `::__kairo_estrh_<len>_<hash>`, an `inline constexpr unsigned char[len + 1]` at global scope, hash FNV-1a 64 over the bytes (`eval_str_hashed`, `eval_str_hash`). EmitPlan collects each from every walked body, eval initializer and value argument (`big_str_bytes`, `note_eval_str`); InterfaceEmitter defines them after the eval helpers, ahead of every type and body, under a per-name `#ifndef __KAIRO_ESTRH_<len>_<hash>` in a header, skipping any an earlier include wrote (`IncludedDecls::estr_seen`). The symbols are weak, so linking several kcc hosts and the module's object is clean.

Run-time literals keep the `reinterpret_cast`.

### eval for

```cpp
{ [&]<usize... K>(::__kairo_iseq<usize, K...>) {
    (... && [&]<usize I>() -> bool { constexpr T i = VAL(I); body; return true; }
             .template operator()<K>());
  }(__make_integer_seq<::__kairo_iseq, usize, COUNT>{}); }
```

`EmitIR::_eval_for` unrolls every `eval for` as a pack expansion, so in each copy `i` is a constant. `continue` is `return true` from the copy, `break` is `return false` (the `&&` fold short-circuits). A `return` sets the function's flag and value slot (`__kairo_efr`, `__kairo_efv`) and stops the fold, and the code after the outermost expansion returns; an inner expansion stops its enclosing copy. A range is `LO + I` with count `HI - LO` (`+ 1` when inclusive); an array reads its elements. An eval generator is a `consteval` function returning a `::__kairo_eval_buf<T>` (`yield` pushes into `__kairo_y`); its count and a `__kairo_eval_arr<T, COUNT>` copy are `static constexpr` locals (`__kairo_egnK`, `__kairo_egK`) ahead of the expansion. Pack and index names carry the nesting depth (`__kairo_K0`, `__kairo_I0`) so an inner expansion does not shadow an outer one. The helpers (`__kairo_iseq`, `__kairo_eval_buf`, `__kairo_eval_arr`, guard `__KAIRO_EVAL_HELPERS`) are written only where an `eval for` or eval generator occurs (`has_eval_for`). C++26 `template for` is not used because clang 22 lacks it. A panicking call inside a copy cannot reach a `try` outside it.

### Function-body eval if

An `eval if` EvalIfFolding could not fold, in a function body, keeps `ConditionalStmt::is_eval`, and EmitIR spells it `if constexpr`. A branch that depends on a generic parameter (`eval if typeof T == U`) is typed once with its diagnostics suppressed, since it may be valid only for some instances. An error that holds for every instance is still reported: an operand pair of two concrete types that does not unify lifts the suppression (`OperatorTyping::_unify_error`), so a poisoned node never reaches codegen unexplained. Other always-true errors in such a branch are still dropped. Whether reporting any of them matches the language reference ("unselected eval-if branches are not type-checked") and clang's discarded `if constexpr` is an open question.
