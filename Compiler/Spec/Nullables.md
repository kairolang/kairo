# Nullable types

`T?` from parse to C++. The system has three parts: the type lowers to a library ADT ([Representation](#representation)); the operators `x?`, `== null`, `===`, `??`, `?.` / `?->` and `unwrap!()` desugar to fixed expansions; and a flow analysis run during typing lets a place the compiler has proven non-null be used as its `T` with nothing written at the use ([Passes](#passes)). The language rules (what each operator means, which uses need a check, how `match` treats null) are in the website reference (nullables); this document covers how the compiler implements them. The slots of the passes below are [Pipeline.md](Pipeline.md#sema-pass-order) (typing) and [Lowering.md](Lowering.md#pass-order) (lowering).

| File | Role |
|---|---|
| `Lib/builtin/module.k` | `null_t`, `enum <T> Nullable { Value { v: T }, Null }` |
| `Compiler/AST/EnumNiche.k` | niche facts Sema and codegen share |
| `Compiler/Sema/Lower/EnumLayoutLowering.k` | layout (tagged or niche) and the role members of every ADT, `niche_of` |
| `Compiler/Sema/Type/NullnessFlow.k` | the null-test classifier and the flow analysis |
| `Compiler/Sema/Type/OperatorTyping.k` | typing of `x?`, `== null`, `===`, `??`, `unwrap!` |
| `Compiler/Sema/Type/MemberTyping.k` | typing of `?.` / `?->` |
| `Compiler/Sema/Type/ControlTyping.k` | `match` on a nullable |
| `Compiler/Sema/Type/StmtTyping.k` | `var x? = e`, `var *y = e` |
| `Compiler/Sema/Check/ShorthandLint.k` | the shorthand lint |
| `Compiler/Sema/Lower/CoalesceLowering.k` | `??`, `?.`, `?->`, `unwrap!`, `===`, `match` with `case null` |
| `Compiler/Sema/Lower/NullTestLowering.k` | null tests to `is_null()` |
| `Compiler/Sema/Lower/NarrowedAccessLowering.k` | narrowed reads to `__value()` |
| `Compiler/Sema/Lower/NullableTypeLowering.k` | `T?` to its record, `null` to the record's null |

Tests: `Tests/Sema/Nullable/`, `Tests/Codegen/nullable/`.

## Representation

### The canonical type and its record

`T?` parses to a `NullableType` canonical. `Nullable` is not a name Kairo code can write; the `?` suffix is its only spelling. Any `T` may be wrapped: a pointer, a record, an ADT, another nullable. `T?` holds its `T` by value, so a record cannot contain a nullable of itself: the field is a by-value cycle, SC002E ([TypeCycleCheck](SemanticChecks.md#check-passes)).

The type is not rewritten in the tree. Each canonical `NullableType` has a write-once `lowered` slot that NullableTypeLowering fills with the record `::builtin::Nullable<inner>` (`SemaContext::lang_record`), walking the canonical table (`CanonicalTypeStore::nullables()`), not the tree. Canonicals are interned build-wide, and `T?` sits inside instance keys (`Box<i32?>`), pointer types and expression types no written type names (`var b = find(3)`); rewriting them would re-key the instantiation registry, which breaks deduction. Every pass after NullableTypeLowering still sees `NullableType`. CXXSpell and EmitPlan spell and plan a `T?` through `lowered`; a `T?` with none is an ICE in CXXSpell naming NullableTypeLowering. A dependent inner gives the primary template over it, which is what a generic body's `::builtin::Nullable<T>` is.

No value conversion is rewritten. Sema checks `T -> T?` and `null -> T?` (`Conversion::_seq`) and records no conversion node, as for every implicit conversion. The record's non-explicit constructors make each one C++ copy-initialization at every site. The `null` literal is the exception: bare, it has no C++ type, so NullableTypeLowering replaces a `null` typed `T?` with the record's null `VariantInitExpr` (`Nullable<T>(::__kairo_vt<1>{})`), which gives an if-expression arm a C++ type. `&null` typed `(*T)?` becomes the same; `&null` against a plain pointer stays the null pointer.

`T? -> U?` with different inners type-checks and fails in clang.

### The library type

`Lib/builtin/module.k` declares:

- `null_t`, an empty struct. `null` is a keyword, so its constant has no Kairo declaration: InterfaceEmitter writes `inline constexpr null_t null{};` after the record (`StructDecl::is_null_type`). C++ hosts spell it `::builtin::null`; Kairo's `null` literal never lowers to it.
- `enum <T> Nullable { Value { v: T }, Null }`, an ADT, so the payload is a real `T` only while present, built in place and destroyed once, and copy and move follow `T`'s.

EnumLayoutLowering gives it what every generic ADT gets (tag, payload union, lifecycle-selected special members) and, for this lang item only, a C++ surface as role functions (`AdtRole::NullDefault` ... `Equal`): `Nullable()`, `Nullable(null_t)`, `Nullable(const T&)`, `Nullable(T&&)`, `is_null()`, the unchecked `__value()` (`T&` and `const T&`), and `operator==` when `T` has one. Every implicit `T -> T?` and `null -> T?` is one of these constructors, so a C++ host writes `Nullable<int> x = ::builtin::null;` or `= 5`. The surface syntax is Sema's desugar onto `is_null()` and `__value()`; `__value()` is called only where the analysis or the desugar's own test proved a value. The members are role functions rather than Kairo bodies because a wrapping class cannot construct its field in place, a `match` in a generic body ICEs, and two constructors `(null_t)` / `(T)` on a generic record are ambiguous (SC064E). Nothing outside the `Nullable` declaration depends on its layout.

### Niche layout

`Nullable` is an ordinary ADT, so EnumLayoutLowering lays it out tagged or niche-filled by the rules every ADT follows ([Lowering.md](Lowering.md#passes); the niche counts and the C++ trait are in [Codegen.md](Codegen.md#interfaceemitter)).

So `(*T)?` is one pointer with `nullptr` as null, standard-layout and passed as the pointer; `Color?` (closed, three variants) is one byte with null at 3, and `(Color?)?` one byte with pattern 4; `((*T)?)?` is tagged because the pointer's one pattern is taken; an `@open` `Color?` is tagged. A `bool?` is tagged until `bool` has a niche, and a record's first niche-bearing field is computed but read by no layout.

### Nested nullables

`(T?)?` is a distinct type, `Nullable<Nullable<T>>`, and is never collapsed, including by generic substitution (`V?` with `V = User?` is `(User?)?`). `T??` does not parse as a type (`??` is the operator); a written `(T?)?` is S055W ("nested nullable '(T?)?': legal and distinct from 'T?', but rarely what you want", `Compiler/Parser/TypeParse.k`). A conversion wraps one level: `T -> (T?)?` is SC028E, `T? -> (T?)?` makes the outer present, `null` is the outer null. `?.` is the one operator that flattens ([Safe access](#safe-access)). Printers write `(i32?)?`.

### The pointer suffix

`*T?` is `(*T)?`, a nullable pointer. A pointer to a nullable is written `*(T?)`, and the printers keep the parentheses.

### Declaration shorthands

`var x? = e` (`VariableDecl::nullable_shorthand`; `var`, `const`, `static`; local or file scope, and the demand path of a global used before its declaration) declares `x: typeof(e)?`, or `typeof(e)` when `e` is already nullable (`StmtTyping::_nullable_once`, shared by destructuring binders). In a generic body the rule is applied to the dependent type, so `T = i32?` gives `(i32?)?`. `var x? = null` (or `&null`) is SC076E ("nothing to infer the nullable's type from") and poisons the binding. The parser refuses `var x?: T` with S058E (fix-it moving the `?` onto the type; recovery reads `x: T?`) and refuses the shorthand on fields (fields never infer).

`var *y = e` declares `y` with `e`'s type and states that it is a pointer; the number of stars is the pointer depth (`var **z = &y`). It never converts: `e` must already be a pointer. `VariableDecl:: pointer_depth` / `pointer_unsafe` / `pointer_range` are parsed in `_parse_var_decl` before the name (`unsafe` counts only directly before a star). `StmtTyping::_check_pointer_shorthand` checks it on both the in-order and the demand path:

- a depth mismatch, a non-pointer `e`, or `unsafe` that disagrees with the outermost pointer is SC266E with a fix-it rewriting the stars; `y` keeps `typeof(e)` and is not poisoned;
- `var *y = e` with `e: (*T)?` and no `?` is SC266E (fix-it inserts the `?`); `var *y? = e` is the nullable pointer, wrapping once when `e` is `*T`;
- in a generic body it is checked against the type as written; when the visible pointer prefix ends in an opaque parameter, more stars than visible are accepted and never re-checked.

`var *y: T` and a field `var *f` are S058E in the parser. The binder shorthand in destructuring and `for` (`for var *x in xs`, `BindingShorthand::Pointer`) is a different feature: it reshapes the binder to point at the element.

ShorthandLint warns SC226W on `var x = e` / `const x = e` with no annotation and no shorthand when `e` is nullable (fix-it inserts `?` after the name), a pointer (fix-it inserts the stars, `unsafe *` for an unsafe pointer), or both. "No annotation" is an inferred slot whose canonical has no source range. A partial shorthand (`var c? = &n`) is not linted. The C-style `for` initializer and locals inside closures are linted; captures, destructuring and `for` binders, dependent types, poisoned and implicit declarations and `eval` are not. Library files are linted like user files. The pass runs in the checks after ShadowCheck.

## Passes

### The null-test classifier

`null_test_of(e) -> NullTest { operand, present }` in `NullnessFlow.k` is the only code that knows the spellings of the null test:

| present | absent |
|---|---|
| `x?`, `x != null`, `null != x` | `!x?`, `x == null`, `null == x` |

It looks through parentheses and through `!` / `not` at any depth (each flips the polarity). It classifies typed trees only: the operand must be nullable and `resolved_op` null, so a user `op ?` on a record is not a null test, and `p == &null` on an `unsafe *T` is a pointer comparison. The analysis narrows through it and NullTestLowering lowers through it, so a spelling cannot narrow one way and lower another. The tests the desugars mint are postfix `x?` and classify like hand-written ones.

### Operator typing

### Null test

`x?` is typed in `OperatorTyping::type_unary` before user-operator lookup and before the dependent deferral: `bool` on a nullable, `bool` on a generic `T?`, deferred on a bare dependent `T`. On a non-nullable it is SC066E with a note at the declaration.

### Comparison with null

`OperatorTyping::type_binary` asks `null_literal_of` on both sides before typing them (`_type_null_compare`). Against a nullable the result is `bool` and the literal takes the nullable's type. Against a non-nullable it is SC260E ("comparing it with 'null' is meaningless") with a note; a raw pointer is SC261E with a fix-it `null -> &null`, and `raw == &null` stays a pointer comparison. `a == b` on two nullables reaches the record's C++ `operator==`; when the payload is a record with a Kairo `op ==` it is SC063E. A record's own `op ==` taking a `T?` is never consulted for `rec == null`.

### Identity

`a === b` requires at least one nullable operand and is not overloadable. `OperatorTyping::_type_identity` resolves `==` on the unwrapped types and records it on the `===` node (`resolved_op`; `op_rewrite = Cmp` for one derived from `op <=>`; `tag_eq` for an ADT), skipping `finish_call_args` (whose convertibility check would read the `T?` operands as values). Rules:

- when a nullable operand holds a pointer (`TypeUtil::identity_derefs`), the comparison is of the pointees, one level, and both sides must be pointers (`(*i32)? === i32?` and `p === 3` are SC033E);
- a nullable raw pointer needs `unsafe` (SC263E), since `===` dereferences;
- `x === null` / `null === x` is SC264E "never true", with a fix-it to `!x?` when `x` is a name or field path;
- a literal side is typed against the other side's `T` (`u8? === 7`);
- a true `===` narrows each nullable place operand; the false branch learns nothing;
- in a generic body, `===` on a `T?` uses the `op ==` that `T`'s bounds declare (R051E / R025E without one); a bounded `T` is never treated as a pointer, so only a written `(*T)?` compares pointees.

### Coalesce

`x ?? y` is typed as `join(T, typeof(y))` asked as written first, so `(i32?)? ?? i32?` is `i32?`. `y` is typed against `x`'s `T`, so a literal fallback takes it (`u8? ?? 7` is `u8`). `y` is typed in the environment after `x`, not under `x`'s false set. In a generic body `t ?? d` with `t: T?` is `T` (or `T?` for `d: T?`). A non-nullable left side is SC065W and lowers to itself. Operand types with no join are SC033E.

### Safe access

`x?.m` is `M?` for a member of type `M`, and stays `M?` when `M` is already nullable (the one flattening). A call `x?.f()` is `R?` (`R` when nullable; `void` for `void` and `-> !` methods), its own `R` kept on `CallExpr::safe_result`. `?->` is the same over a nullable pointer. `MemberTyping` makes `?.` / `?->` on a non-nullable SC260E (note at the declaration, fix-it removing the `?`). The result is an rvalue (`f?.v = 3` is SC071E). Steps after a `?.` up to the next one act on the value (`f?.inner.w` is `w`'s type made nullable); a call ends the chain (`f?.me().v` reads `.v` on `Foo?`, R025E). Arguments are typed before the call, not under the receiver's true set. A `?.` to a function-pointer field that is then called is not handled.

### Unwrap

`unwrap!(x)` is a parser intrinsic: the preprocessor passes `unwrap` `!` through raw (the name is reserved, like `label!` / `jump!`), and ExprParse builds an `UnwrapExpr` (S060E when malformed). `OperatorTyping:: type_unwrap` types it `T` with cv kept (dependent `T?` gives `T`); a non-nullable operand is SC260E with fix-its removing `unwrap!(` and `)`. It is not a read of `x`; afterwards a place `x` is NonNull (`NullnessFlow::unwrapped`). It is an lvalue when the operand is a place. On null the program terminates through the crash path (not a panic: no `try` catches it and it is in no panic set; see [Panic.md](Panic.md#model)).

### Nullness analysis

The analysis runs during typing, because the type of a use depends on it: `if a != null { r += a }` types `a` as `i32` only through narrowing. ExprTyper and its mixins report what they walk and ask at each use; `NullnessFlow` owns the state, the condition sets, the joins, the weakening and the loop pre-scan. A narrowed use is recorded on its node, so the lowering needs no analysis of its own.

The analysis is sound and incomplete: when it cannot tell, the answer is Maybe.

### Places and states

A place is a local, a parameter or a global, plus a path of fields read with `.` (`o.cache.v`): a vector of decls, root first. A fact is `{place, state, why, at, global}` with state NonNull, Null or Maybe; a place with no fact is Maybe. The environment is a list of facts plus `dead` (unreachable: a join ignores it, a read there is allowed). Joins take the weaker state (`NonNull ⊔ Null = Maybe`). Assigning a place drops the facts of every path under it. The environment stack follows `TyperFrame` (`enter` / `leave` for a function or closure body), plus `var_type`'s demand path and field defaults, so a body typed mid-walk sees nothing of its caller's. A `->` step and a subscript are not places; reading through one is SC265E with "copy it to a local".

### Definitions and conditions

`define` / `assign` set the place's state from the right side: a value of non-nullable type converted to `T?` and `&e` give NonNull; `null` gives Null; another place gives that place's state; anything else (a call returning `T?`, an untracked field, `??` with a nullable right side) gives Maybe. A nullable parameter starts Maybe.

`cond_of` / `store_cond` give a condition a true set and a false set: `x?` sets NonNull / Null; `!c` swaps; `a && b` types `b` under `a`'s true set, with true set both true sets and false set the join of `a`'s false set and (`a` true, `b` false); `a || b` dually. An `if`, an if-expression and the `??` expansion start their arms from the sets. `diverge` marks the environment dead after `return`, `break`, `continue`, `panic` or a `-> !` call, so after `if !x? { return }` the join leaves `x` NonNull.

### Weakening

A write the analysis cannot see the value of makes a place Maybe, with the cause recorded for the diagnostic note:

- `inout_arg`: an `@inout` argument (marked, unmarked, or through a `fn` pointer) weakens the place and every path under it;
- `mutable_self_call` / `operator_call`: a non-const method or user operator weakens every path strictly under its receiver; the receiver itself stays NonNull;
- a pointer: `&x` is recorded where it is typed (`address_taken`) and weakens nothing by itself. Until a consumer accounts for it (the `@inout` marker, a `*const` parameter) it has escaped, and every later call (`after_call`) and every write the analysis cannot place (`*p = v`, `p->f = v`, `++*p`, a mutable `(*p).m()`: `write_through`) weakens `x`.

A `const` pointer, a `const self` call and a by-value pass weaken nothing. A move does not change the state; MoveCheck's SC052E reports a later use.

### Loops

The body is typed once, from the head, so the head's state must hold on every back edge. `loop_enter` runs `NullLoopScan`, a path-sensitive scan of the untyped body: for each place proven at the head it asks whether a path to the back edge (end of body, each `continue`, then a `for`'s update) may keep it (`NULL_SCAN_KEPT`), give it a value known non-null (`NULL_SCAN_VALUE`), or lose it (`NULL_SCAN_LOST`). NonNull survives keep or value; Null survives keep only. "Known non-null" is the [definition rule](#definitions-and-conditions) read before typing: a literal, `&e`, a constructor, a call of a function declared `-> T` for every candidate, a place declared `T`, a builtin operator on scalars, a cast to `T`, an if-expression of those. Losses mirror what the typer weakens. If-expressions, `&&` / `||` / `??` right sides, match and try expressions, catch arms and `finally` are scanned unordered. One pass plus a join is the fixpoint for nested loops. Globals and escaped places are Maybe at every head.

The condition is typed at the head, so `while x?` proves `x` at the top of the body whatever the body does. After a `while`: its false set joined with each `break`; after a `for`: the head joined with each `break`; after `loop`: the breaks. A labeled `break` joins into its own loop (`on_break`). A `catch` arm starts from the state before the `try` with what the body may change dropped (`try_entry`).

### Match

`ControlTyping::match_null_first` / `match_arm_enter` / `match_guard` (shared by the statement and expression forms) implement the rule that a match on `T?` answers null first. When arm 0 is a lone, unguarded `case null`, `MatchStmt` / `MatchExpr::null_arm` is set: that arm starts Null, every later arm (`default` included) starts NonNull, and a binding pattern binds the unwrapped `T`. Otherwise it is SC254E "a match on 'T?' must answer null first" on the scrutinee: a fix-it inserting `case null { }` (and a newline at the arm's indentation) when no arm mentions `null` and the match is a statement; a note for the expression form (the fix-it cannot invent the value); a note at a late, guarded or alternated `case null`. The scrutinee is then poisoned so PatternChecking does not judge the arms. A `case null` after a valid first arm is its own error unless `T` is itself nullable. PatternChecking and PatternCompilation drop arm 0's row and root the column at `T`, keeping arm numbers. A guard's true set refines its arm; the post-match join is the arms' end states, diverging arms excluded, for every match (a match is exhaustive or SC120E).

### Aliases and closures

A carrier is a local holding a pointer or a closure that captures by non-const pointer. It carries the places a write through it or a call of it may change (`_carriers` per body): `var p = &x` carries `{x}`; a closure's set comes from `closure_made` (named non-const `|*x|`, every outer local the body names under `|*|`, plus what each by-copy captured carrier carries); a copy `var q = p` carries the same. Escape is lazy, as for a fresh `&x`: a carrier's use escapes unless a consumer accounts for it: `*p`, `p->`, a call of it (`call_value`, which weakens what it carries), a copy into a local, a `*const` parameter, the `@inout` marker. Any other use leaves it escaped, including `p?` / `p == null` (conservative), and then every call weakens what it carries. A write that is no place weakens what its pointer carries when that is a carrier, else every escaped place.

A closure body (`_closure_entry`) starts with each by-copy capture in the state it had where the closure was made, less what the body assigns it (the copy persists between calls). Inside a `|*x|` closure, `ExprTyper::_capture_view` types `x` as `*T` (marked `capture_ptr`), so `x` is no place and `*x` is the variable's place: rooted at its decl, starting Maybe, and treated as global (`_shared`), since anything holding a pointer to it may write it during a call. `self` is excluded under `|*|`. The loop pre-scan and the catch-arm scan follow carriers; a pointer that may outlive one iteration is lost at the head.

### Globals

A global or static is Maybe at function entry, and `after_call` makes it Maybe again after any call; a check narrows it until the next call.

### Narrowed reads

A read is narrowed by its consumer, not at the name. `_type_ident` (and a chain ending on a nullable field) only records the state the place had at that point (`note_read`), so a consumer typed after a later assignment (`f(x, x = null)`) still reads the state where the name was written. A consumer that needs the value calls `read_value`; on NonNull the use is typed `T` and marked (`NamedIdentExpr::narrowed_from`, `ChainExpr::Step::narrowed_from`, `UnaryOperatorExpr::narrowed_from` for `*x` of a pointer capture), each mark holding the `T?`. The consumers:

- OperatorTyping: every binary operator but `==`, `!=`, `??`, `===`, `in`; `==` / `!=` read a proven value when the other side is not nullable; every unary operator but `&` and postfix `?`; compound assignment, both sides;
- MemberTyping: `.` / `->` on the base or the path so far; a subscript's base;
- `check_convertible`: `T?` where a `T` is wanted (initializers, `return`, arguments through a `fn` pointer), also in a generic body;
- `CallTyping::_narrow_args`: only when no candidate takes the arguments as written and one does with the nullable places read, so a `T?` overload wins and a `T?` parameter is never asked;
- `require_bool` (`if b` on `bool?`); `_call_through` (a nullable `fn` pointer);
- an f-string hole and a proven if-expression arm, both soft: proven narrows, unproven keeps `T?` and its ordinary error.

Uses that need no value (assigning the whole nullable, passing it to a `T?` parameter, `x?`, `== null`, `??`, `?.`, `===`, `unwrap!()`) never ask, so `var y = x` stays `T?`. ChainBinding leaves `.` / `->` on a declared nullable unbound (NeedsInference) for MemberTyping; a nullable that is no place (`mk().v`) binds and fails R025E. No mode inserts a guard: a Maybe or Null read is a compile error in every mode.

### Access diagnostics

A value read of a Maybe place is SC265E "'x' may be null here; check it with 'if x?' first"; of a Null place, SC265E "'x' is always null here" (`NullnessFlow.k`). One note (`_why_note`) names the cause recorded on the fact: the definition or assignment that made it Maybe or Null, the failed test on this path, a call that may change a global or a closure-reached place, a loop that may change it, an `@inout` argument, a mutable-`self` call, a `try` body, a write through a pointer, a call running a closure that holds a pointer, an escaping pointer, a nullable parameter, a global, a captured variable, or otherwise "declared nullable here" (a join of NonNull and Null has no single cause).

The precedence trap: in `if a? && a > 0 || a < 0` the `a < 0` is typed under the false set of `a? && a > 0`, where `a` is Maybe. While the right side of `t && y || z` is typed (`t` a present test of place P, `y` not a test of P), its access errors are held (`trap_begin` / `trap_end`). If every held error reads P, the first gets two insert fix-its, `(` before `y` and `)` after `z`, giving `a? && (a > 0 || a < 0)`, and a note naming `unwrap!(P)`; otherwise all are reported plainly.

### Lowering passes

Four passes run as one block, in this order, before OperatorLowering: the expansions produce `==` on `T` (from `===`) and member calls on `T` (from `?.`), which OperatorLowering and CallLowering must still see. All four run after CopyMoveLowering. Each builds its output typed, in the shape the typer gives the same code written by hand, so later passes need no knowledge of where it came from.

### CoalesceLowering

Expands the operators that choose a value, and a `match` with a null arm:

| Source | Expansion |
|---|---|
| `x ?? y` | `if x? => <x marked> else y` |
| `x?.m`, `x?.f(args)` | `if x? => <x marked>.m else null`; `a?.b?.c` tests each optional prefix, joined with `&&` left to right: `if a? && a.b? => a.b.c else null` |
| `unwrap!(x)`, place | `*({ if !x? { unwrap_failed(m, n) } &x })`, an lvalue |
| `unwrap!(e)`, other | `({ var t = e; if !t? { unwrap_failed(m, n) } t as T&& })` |
| `a === b` | `(a? && b?) && a == b`; through nullable pointers `*a == *b`; a non-nullable side contributes no test |
| `match x { case null { A } arms }` | `{ if !x? { A } else { match <x marked> { arms } } }`; arm 0 stays in the list, emptied and unreached. The expression form is `x? ? match : a0` |

The test is a postfix `x?` (bool, no `resolved_op`), lowered by NullTestLowering; the then-arm read is marked narrowed, lowered by NarrowedAccessLowering; the if-expression is typed as the operator was, which EmitIR spells `(c ? a : b)`. An operand appears twice in an expansion, so it is evaluated once: a place (`LowerSynth::pure`: a name, a field path, `p->c`) is read twice; anything else is bound to a `__kairo_coalK` (or `__kairo_safeK` for a `?.` base) local in a statement expression, and the then-arm moves the value out (`static_cast<T&&>`), because CopyMoveLowering already ran and a copy would duplicate a move-only payload. `===` binds non-place operands left to right. `?.` expands at the `CallExpr` for a call (arguments only in the then-arm) and at the `ChainExpr` otherwise; a `void` call becomes `if c { call }` in a statement expression.

`unwrap!` lowers to a statement, not an if-expression, because C++ `?:` rejects a `void` arm (if-expressions with a `-> !` arm are). Its message is built at compile time: "unwrap!(x) on null at `<file>`:`<line>`:`<col>`" plus a newline, with the file as the SourceManager names it. `unwrap_failed(msg: *const u8, len: usize) -> !` (lang item `WellKnownType::UnwrapFailed`, `Lib/builtin/errors/crash.k`) calls `kairo_rt_crash` (`Lib/rt/crash.c`), which writes the message to stderr and aborts: exit status 134.

### NullTestLowering

Lowers every expression `null_test_of` classifies: present tests become `!x.is_null()`, absent ones `x.is_null()`. Only the outer level is tested, so on a `(T?)?` it asks the outer nullable. `is_null()` is found on the lang item's layout by `AdtRole::IsNull` (an instance shares the pattern's layout) and called through `LowerSynth::member_call`. The `null` literal a comparison held is dropped with the comparison. It runs before NullableTypeLowering because it classifies by `NullableType` and the `null` it drops would otherwise become a `VariantInitExpr`; before OperatorLowering because a leftover `x == null` would have a record operand, which EmitIR rejects.

### NarrowedAccessLowering

Spells each mark:

| Marked read | Lowered |
|---|---|
| a name `x` | `x.__value()` |
| a field path `o.cache` | `o.cache.__value()` |
| a path through it `o.cache.v` | `o.cache.__value().v` |
| a pointer through it `p->m()` | `p.__value()->m()` |
| a pointer capture's `*x` | `(*x).__value()` |

A mark on a middle chain step splits the chain there and the rest continues from the call. The receiver is put back to the `T?` the mark holds and the call is the `T`. `__value()` (`AdtRole::ValueRef` / `ValueCref`) returns `T&` or `const T&`, so the call is an lvalue: a write through a narrowed record writes the payload, and CopyMoveLowering's `x as T&&` becomes `static_cast<T&&>(x.__value())`, a move of the value. Its order against NullTestLowering is free (a null test's operand is never a narrowed read).

### NullableTypeLowering

The last nullable pass, so the others still see `NullableType`. Fills each canonical `T?`'s `lowered` record and replaces each `null` typed as a nullable with the record's null `VariantInitExpr` ([The canonical type and its record](#the-canonical-type-and-its-record)). It must follow CopyMoveLowering: that pass decides a transfer from the value's lifecycle, which ClassLifecycle answers for a `NullableType` from its inner, while a freshly minted `Nullable<Uniq>` instance would have no facts yet. It does nothing when the build has no builtin root, and ICEs if the lang item is not an enum or has no payload-less variant.

### Diagnostics

| Code | Meaning |
|---|---|
| S055W | written nested nullable `(T?)?` |
| S058E | `var x?: T`, `var *y: T`, shorthand on a field |
| S060E | malformed `unwrap!` |
| SC028E | `T -> (T?)?` |
| SC033E | `??` operands with no join; `===` sides that do not unify |
| SC065W | `??` on a non-nullable left side |
| SC066E | postfix `?` on a non-nullable |
| SC076E | `var x? = null` |
| SC226W | the shorthand lint |
| SC254E | match on a nullable does not answer null first |
| SC260E | `== null`, `?.` / `?->`, `unwrap!` on a non-nullable |
| SC261E | raw pointer used as nullable |
| SC263E | `===` on nullable raw pointers outside `unsafe` |
| SC264E | `=== null` |
| SC265E | value read of a Maybe or Null place |
| SC266E | pointer shorthand mismatch |

## Codegen

Everything nullable reaches codegen as ordinary nodes: member calls of `is_null()` and `__value()`, `VariantInitExpr`s, if-expressions and statement expressions. The C++ side of the lang item (the role members, `null_t` and its constant, the niche specialization and its `static_assert`s) is written by InterfaceEmitter ([Codegen.md](Codegen.md#interfaceemitter)); CXXSpell spells a `T?` through its `lowered` record.

The checked downcast `p as (*D)?` (`TypeCastExpr::checked_downcast`, set by CastTyping) is spelled by `EmitIR::_checked_downcast` as

```cpp
[](D* __kairo_dc) noexcept -> N { return __kairo_dc ? N(__kairo_dc) : N(); }(dynamic_cast<D*>(p))
```

with `N = Nullable<D*>`. A lambda keeps it an expression wherever a cast is and adds nothing to the preamble. A generic pointee is accepted and checked by C++ per instance. A nullable source `(*A)? as (*D)?` is SC027E.
