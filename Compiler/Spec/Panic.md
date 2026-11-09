# Panic

How the compiler implements `panic`, `try` / `catch` and the crash family, from the result type through effect checking and lowering to the C++ it emits. What these constructs mean to a Kairo program is defined by the language reference (panic, and C and C++ exceptions); this document covers how the compiler realizes that meaning.

A panic is a returned value. A function that may panic returns a tagged result, `Panic<T, E...>`; every call site tests the tag and either continues with the value or hands the error on. Nothing unwinds, and every Kairo function stays `noexcept`. The system has four parts:

| Part | Section | Implemented by |
|---|---|---|
| The result type and its layout | [Model](#model) | `Lib/builtin/errors/panic_result.k`, `Compiler/Sema/Type/PanicSets.k`, `Compiler/Sema/Lower/EnumLayoutLowering.k` |
| Each function's set of error types | [Effect sets](#effect-sets) | `Compiler/Sema/Check/EffectPropagation.k`, `Compiler/Sema/Check/PanicEffectChecking.k` |
| The passes that check and rewrite | [Passes](#passes) | the two above, `Compiler/Sema/Lower/PanicLowering.k` |
| The C++ that results | [Codegen](#codegen), [Interop with C++ exceptions](#interop-with-c-exceptions) | `Compiler/Codegen/Emit/InterfaceEmitter.k`, `Compiler/Codegen/Emit/EmitIR.k`, `Compiler/Codegen/Emit/CXXSpell.k` |

## Model

### The result type

`Panic` is a builtin variadic ADT enum and a lang item (`WellKnownType::Panic`), declared in Kairo with the same pack-expanded variant syntax user code may use:

```kairo
pub enum <T, ...E> Panic {
    Ok  { value: T },
    Err { error: E }...,
}
```

`T` is the declared return type (`void` allowed); `E...` is the function's panic set. A function marked `panic` whose final set is non-empty returns `Panic<T, E...>`; one whose inferred set is empty returns plain `T`.

User code never names `Panic`: outside the builtin root a written `Panic<...>` is SC116E, with a note at the declaration (TypeResolve; `--test-panic-type` lifts this for tests). `Panic<T, E...>` is still an ordinary canonical type that later passes never erase, so a later language form can bind a call's result to a variable and consume it elsewhere. A panic result held in a variable is SC116E ("a stored panic result"; PanicEffectChecking); that form is not implemented.

The pack-expanded variant `V { ... }...` (one variant per element of the pack, told apart by payload type) is a general language feature; its rules (last variant only, no niche, equal elements deduplicated where the type is formed) are in [Generics](Generics.md#instantiation-model). `Panic` is the one ADT that also sets the layout knobs below.

### Layout

`EnumLayoutLowering` lays out `Panic` in a type-id-tag mode (`AdtLayoutKnobs`, set for the lang item by identity); copy, move and destroy still come from the general ADT machinery ([Codegen](Codegen.md#interfaceemitter)).

| Field | Content |
|---|---|
| word 0, low half | tag, `u32`: `Ok` is 0; an `Err` element's tag is its error type's [type id](#type-ids) |
| word 0, high half | panic [site id](#site-ids), `u32`, written with the tag as one 64-bit store and copied wherever the tag is |
| payload union | `alignas(__kairo_payload_offset)`, a static constexpr member equal to `__kairo_max_align<P...>(8)`, so `max(8, alignof(T), alignof(E)...)` per instance |
| `void` Ok | holds `__kairo_nv<T>`, the empty `__kairo_unit` for `void` (Sema sizes it as 1 byte) |

Because tags are global type ids, `catch e: E` is one compare, `tag == type_id<E>`, in every set that holds `E`, and widening a `Panic<T, A>` into `Panic<U, A, B>` copies word 0 unchanged. Every element is held in one `__kairo_pu<__kairo_Err_t<E>...>` member read by `__kairo_get<K>()`, `K` the element's position in the canonical set, so no per-type member name exists. Any layout knob turns off the niche and common-prefix layouts. Sema predicts the payload offset (`EnumLayoutQuery::payload_offset`, `InstanceEntry::payload_offset`); nothing hardcodes 8.

`sizeof(Panic<T, E...>)` is 8 plus the widest of `T` and the `E`s, rounded to the union's alignment. It is 16 bytes, returned in two registers on x86-64 SysV, only while every payload is at most 8 bytes. The cliff is per instance, so one wide error type moves every function returning that set to a memory return. OPT002R reports it at the set's first formation in the TU (`InstanceEntry::formed_at`), naming the widest payload. Sema sizes only plain arrays and plain records (no generic parameters, base, virtual method or import), so other payloads produce no remark.

### Canonical sets

A panic set is canonical: deduplicated, sorted by type id, built only by the compiler. `Panic<i32, A, B>`, `Panic<i32, B, A>` and `Panic<i32, A, B, A>` are one type however they are reached (a written type, a `Panic<...>::Ok` path, a deduced argument). `PanicTypeIds` implements `PackSetOrder`; the driver installs it in the `CanonicalTypeStore` and the `InstantiationRegistry`, so the order is applied wherever a `Panic` type is formed. An element with no id (a dependent type) leaves the order as written; such a set is ordered by C++ per instance ([Generic templates](#generic-templates)).

`PanicSets::form(at, T, elems)` is the one entry that forms a result type: it canonicalizes, checks collisions, forms the lang-item record and notes `formed_at`. Inferred sets therefore never depend on statement order, and the layout depends only on which types are in the set.

### Type ids

A type id is FNV-1a 32 (offset 2166136261, prime 16777619) over the type's C++ spelling, masked to 32 bits (or to `--test-panic-id-bits`); while the result is 0 (reserved for `Ok`), one more byte 0xFF is hashed into the full state and the mask applied again (`panic_id_of`). Guards and record names key on FNV-1a 64 of the same text (`panic_fnv64`).

The spelling (`PanicTypeIds::spelling`) is the one name every TU, and the C++ specialization the id is read through, must already agree on: a Kairo record's CXXSpell qualified name with its arguments (`::app::cfg::ConfigError`), an imported C++ record's clang spelling, a builtin's emitted name, `T*`, `T[N]`, `::__kairo_fn<R(A,B)>`. `usize` / `isize` hash as the fixed-width builtin they are in C++ (`PanicTypeIds::size_types`). Dependent types, references and interfaces have no id. Two Kairo builtins that are one C++ type under two spellings would get two ids.

Two different types with one id cannot share a set, since their tags would be equal. `PanicSets::check_collisions` reports SC223E when a set is formed, with a note at each type. Every widening `S -> R` has `S ⊆ R`, so checking each set at formation covers every later copy of a tag word. One type written twice is one element, never a collision.

Test hooks: `--test-panic-type` (source may name `Panic<...>`), `--test-panic-id-bits=N` (ids masked to N bits, to force collisions), `--print-panic-sets` (each instance's set in order, its ids, Sema's size and payload offset), and the builtins `__builtin_type_id<T>()` and `__builtin_panic_site()`, answered by EnumLayoutLowering like `__builtin_niche_of` (`Tests/Codegen/panic/lang_item.k`).

Codegen never hashes: `EnumLayoutQuery::sweep` records each instance's element ids on its `InstanceEntry`, and InterfaceEmitter writes them as `__kairo_tid<E>` specializations ([Codegen](#codegen)).

### Site ids

The `u32` beside the tag identifies the `panic` statement that raised the error. It is set at the `panic` and never rewritten: propagation, widening and re-panic copy word 0 as it is.

The id is FNV-1a 32 of `<path>:<byte offset>`, the path as the SourceManager names the file. `PanicSets::site_id` assigns it and registers the site in `TranslationUnit::panic_sites`; an id that is 0 or already held by another site of the TU is rehashed (one more 0xFF byte) until free. The same location asked twice is the same site. Uniqueness holds within a TU by construction; ids from different TUs may collide, which affects only messages ([The C++ view](#the-c-view)).

Each TU writes its sites to a linker-collected table (`EmitIR::_panic_sites`):

```cpp
struct __kairo_panic_site { unsigned id; unsigned line; unsigned col; const char* file; };
[[gnu::used, gnu::section("__kairo_panic_sites")]]
static const ::__kairo_panic_site __kairo_ps_<key> = { id, line, col, "path" };
```

Mach-O names the section `__DATA,__kairo_psite` (16-byte limit). Records are `static`, so a `.k` file included into several TUs by kcc writes the same record into each; the lookup treats records equal in all four fields as one site. A site rehashed in one TU but not another has two ids, each with its own record.

### Error types

Any type can be an error type. The only requirements come from the mechanism: an error is returned and propagated by value, so it must be movable (`ClassLifecycle`'s fact; Unknown says nothing) and a complete value type (not a reference, not `void`, not a Kairo record without a definition). PanicEffectChecking checks these at every `panic`, every declared-set element and every `catch` filter that is not a C++ exception arm; a violation is SC212E with a note at the type. C++ types are ordinary payloads with ids from their spelling.

`fn op panic (const self) -> string` is an optional operator giving the human-readable message. It is used only on the display path (`what()`, [The C++ view](#the-c-view)); raising, propagating, widening and dispatching never call it. OperatorSignatureCheck enforces the signature: it is nullary, and a non-`const` `self` is an error with a fix-it inserting `const`. An `extend` may give a type `op panic` under the ordinary extension rules. Its C++ name is `LowerTargets::op_panic` (`__kairo_op_panic`).

### Crashes are not panics

A crash ends the process at once. It joins no set and no `try` catches it. The crash family is: `crash!()`, `unwrap!` on null, a checked `as` into a closed enum that misses, a script global read before its line ran, and the asserting downcast `p as *D`. Putting programmer errors into sets would make every function holding one `panic`.

All of them reach one runtime entry, `kairo_rt_crash(msg, len)` (`Lib/rt/crash.c`):

- `crash!` is a `pub macro` in `Lib/builtin/module.k` over `crash_with(msg: string = "") -> !` (`Lib/builtin/errors/crash.k`), which passes the string's data and length once. It adds no location.
- The compiler's checks call the `UnwrapFailed` lang item `unwrap_failed(msg, len) -> !`. `LowerSynth::crash_call` builds each message whole at compile time (what failed and `file:line:col`, a byte literal and its length, no trailing newline).

`kairo_rt_crash` follows signal-handler rules, in order: an atomic re-entry flag (a crash while crashing skips the message); the message and `\n` copied into a static buffer of `KAIRO_RT_CRASH_MAX` = 4096 bytes (PIPE_BUF, so the line cannot be split by another thread's output) and written with one `write(2)` to fd 2, retried on EINTR and short writes; SIGABRT reset to `SIG_DFL` and unblocked; `abort()`; `__builtin_trap()` if abort returns. No stdio, allocation, locks or Kairo code. Windows uses `_write` and `signal(SIGABRT, SIG_DFL)`; wasm/WASI writes and aborts. Neither is tested.

Not routed through it: slice bounds checks in `Lib/builtin/containers.k` and MatchLowering's unmatched-arm policy are a bare `__builtin_trap()`. `assert`, `todo!()` and `unreachable!()` are not yet runtime crashes.

The asserting downcast is C++'s `dynamic_cast`, which handles targets below `D` and second-base pointer adjustments that a type-id compare could not. CastTyping sets `asserting_downcast` (the source must be polymorphic, SC025E) and always warns, SC253W with a fix-it inserting `?` (the checked form `p as *D?` is the recoverable one). OperatorLowering expands it to `({ var s = p; var d = s as *D [dynamic_only]; if s && !d { unwrap_failed(m, n) } d })`; a null `p` stays null. Open: a dependent pointee is SC091E; `-fno-rtti` breaks both downcast forms; in a global initializer the expansion is a statement expression at file scope.

## Effect sets

Every function and closure has a panic set: the error types that may leave it. The set is the effect; `Panic<T, E...>` is its representation.

### Inference

A bare `panic` body's set is inferred from what can leave it:

| Source | Adds |
|---|---|
| `panic X` | `typeof(X)` |
| a call of a panicking function outside a `try` that discharges it | the callee's set, less what enclosing `try` arms catch |
| `panic e` of a typed arm's binding | that arm's type |
| `panic e` of a bare arm's binding | what the `try` body left after the typed arms |
| `panic e` of a C++ exception arm's binding | the arm's C++ type (a new panic from this site, not a re-panic) |

A call is anything ExprTyper resolved to a function: a `CallExpr` (callee or `ctor_decl`), `resolved_op` on unary, binary, assign, subscript and cast nodes, a ranged `for`'s `op in`, and a call through a `fn` value (which adds its type's set). `unwrap!`, `assert`, `crash!` and the asserting downcast add nothing ([Crashes are not panics](#crashes-are-not-panics)).

A `where` group's set is the union of its members' own sets (`FunctionDecl::where_group`); each candidate keeps its member's contract and the dispatcher forwards.

### Declared sets

`panic(E1, E2)` fixes a function's set. Its elements resolve in the declaration's scope like its parameters; a poisoned element poisons a `fn` type; duplicates are not diagnosed (the canonical set deduplicates). Parsing (`panic` followed by `(` on the same line in specifier position; `panic()` is S055E) is described in [Parsing](Parsing.md#disambiguation).

A declared set must be written where the set is a contract or there is no body to infer from. A bare `panic` there is SC218E:

| Position | Why | Fix-it |
|---|---|---|
| `fn` type | no body | none (a note says so) |
| interface requirement | no body; contract for conformers | none (a note says so) |
| `virtual` base method | contract for overriders | writes the inferred set, or removes `panic` when it is empty |
| closure | readability | as above |

An `override` may infer. Subset rules, each SC208E with an edit adding the missing types to the declared set (none when the declared set names its own type parameters):

- an override's set is within the base method's (matched by name or operator symbol, arity and parameter types, nearest base first); overriding a non-panicking method with a panicking one is the same rule against the empty set;
- a declared conformer's set is within the requirement's (`ConformanceRow::reqs`); a structural conformance (a row with no declared `impl`, found at a generic's use) is held to it at the instance's use, once per row per TU (`_structural_rows`);
- a method meeting two requirements, or a base and a requirement, with different sets is SC116E.

Base and requirement sets are read through the base record or the row's interface instance (`panic_set_through`), so a generic base's or interface's parameters are substituted.

### The `fn` type rung

The set is part of a `fn` type's identity: `CanonicalTypeStore::func` keys on `canon_panics` and the canonical set (`FunctionPointerType::panic_set` on the canonical node; the caller canonicalizes, since the store cannot order types). Conversion has a `fn` rung: same signature and `S ⊆ S'`; a non-panicking function converts to any panicking `fn` type. A failed conversion is the ordinary SC028E, whose types print their sets.

A function's value type carries its declared set. A bare-`panic` function used as a value is SC219E with an edit writing its inferred set: its value type is fixed during typing, before the set is solved.

### Where nothing may leave

Each body kind fixes what may leave it. A site whose leftover is not allowed is reported at the site, with a note at the call chain's origin.

| Body | May leave | Otherwise |
|---|---|---|
| function or closure without `panic` | nothing | SC221E; edits: mark it `panic`, or `try <call> catch => crash!()` at a call |
| declared `panic(...)` | the declared set | SC221E, edit adds the type to the list |
| bare `panic` | its inferred set (holds every leftover by construction) | - |
| `main`, a script's top level | nothing | SC221E "a panic cannot reach 'main'"; the `try` edit only |
| field default, parameter default | nothing | SC221E (a `try` there is allowed: FieldInitLowering makes it a function body) |
| constructor, destructor | nothing | SC221E with the `try` / `crash!()` edits; a note that fallible construction is a static factory |
| global or static field initializer | no panicking site and no `try` at all | SC222E: it runs at file scope with no function to propagate to and no statement expression to hold a `try` |

A local `static` belongs to its function. Script globals are initialized in the synthesized `main` ([Script mode](ScriptMode.md#desugaring)), so they follow `main`'s row.

Declaration rules:

| Rule | Code |
|---|---|
| `fn main() panic` | SC213E |
| `panic` together with `-> !` | SC214E |
| `panic` on any constructor or the destructor | SC215E, edit removes it |
| `panic` on what runs with no call written: an `@implicit op as`, `op panic` | SC215E |
| inferred set on a `pub` function in a library build (`--shared`, `SemaOptions::library_build`, user files only) | SC217W, edit writes the set |

Neither a constructor nor a destructor ever adds to a caller's set.

### `try` and arms

The walk routes each site's set outward through the enclosing `try`s, innermost first. A panic inside an arm is outside its `try`. Each typed arm discharges exactly its type; a bare `catch` discharges the rest; what is left goes to the next `try` or the body ([Where nothing may leave](#where-nothing-may-leave)). Exhaustiveness needs no pass of its own.

Sets have no subtyping: an element is an exact type. `catch e: Base` does not catch a `Derived` error, and a set holding both has two tags.

PanicEffectChecking records for PanicLowering:

- `TryCatchStmt::reach` / `TryCatchExpr::reach`: the body's set.
- `CatchArm::is_dead`: a typed arm whose type is not in `reach`. It is SC210W with a remove edit (also when nothing in the body can panic), and gets no compare. A warning, so that removing an error from a callee's set is not a breaking change for callers that catch it.
- `PanicStmt::repanic`: the arm binding a `panic e` re-raises, so lowering forwards word 0 unchanged.
- The bare binder's type: ExprTyper types a bare `catch e` as `Panic<>` before any set exists; PanicEffectChecking retypes it, and every use of it, as `Panic<void, L...>` over what the typed arms left (`PanicSets::form`).

Arm errors: two typed arms for one type, SC209E with a note at the first; any arm after a bare `catch` in the statement form, SC240E (ArmOrderCheck; the expression form's parser rejects it, S054E). A C++ type outside the set is a [C++ exception arm](#c-exception-arms): never dead, not held to the payload rules. A C++ type in the set is a panic arm.

An expression arm may leave: `=> return [v]`, `=> break [label]`, `=> continue [label]` parse as a `StmtExpr` marked `is_jump`, which ExprTyper types `!`. Any `!` arm (including `crash!()` or a call of a `-> !` function) is lowered as its statement, never stored as the arm's value.

A `finally` whose previous sibling in its block is a `TryCatchStmt` is SC211W (`visit_compound_stmt`), with notes at the block's closing brace and at the `try`, and the idiom of placing the `finally` above the `try` offered as a note without an edit. The parser never attaches a `finally` to a `try`, so `} finally {` and a `finally` on the next line are one tree; both warn, including when the `finally` is the block's last statement (an early exit from the `try` still skips it). A top-level `finally` in a script is already an error (LoopContextCheck).

### The solve

`EffectTable` (`EffectPropagation.k`) solves every bare-`panic` function and closure of a group of TUs to a fixpoint over the call graph. Sets only grow and are bounded by the types the bodies name, so the iteration terminates. Each body is walked once by `PanicWalk`, which collects its sites, its `try`s and what leaves; `EffectCollect` gathers the entries. The solve runs at the Typed barrier, once every TU of an import cycle has finished typing ([Pipeline](Pipeline.md#phase-barriers)); with no driver table, PanicEffectChecking builds one for its own TU. An importer in the same invocation reads a callee's solved set off its `FunctionDecl`.

Results live on the declaration, written on every link of a redeclaration chain: `FunctionDecl::panic_eff` / `ClosureExpr::panic_eff`, with `panic_state`:

| `PanicSetState` | Meaning |
|---|---|
| `None` | not solved |
| `Final` | `panic_eff` is the set; empty means it does not panic |
| `Unknown` | its TU stopped before Typed |
| `Diverged` | a generic set that grows without bound; read as Unknown |

A set that cannot be known says nothing: a callee whose TU stopped before Typed, an undefined bare-`panic` prototype, a gated callee. Its call adds nothing and is never reported, so one failure does not cascade. Per call, `PanicKnown` is `No`, `Set`, `Unknown` or `Unbound` (below).

The canonical order in the checker is the type-id order (`pset_before` asks `PanicTypeIds`), so the set a body is checked against and the result type PanicLowering forms from it are one list, and messages name sets in that order.

### Generic bodies

A generic body's set is computed once, at its definition, like any other. It is the union of what it raises, its concrete callees' sets, and the declared sets of the bound requirements it calls; nothing is inferred per instance. It may name the body's own type parameters (`panic x` with `x: T` adds `T`). A call reads its callee's set at the call (`panic_call_set`), with each type parameter substituted through Deduction / Substitution:

| Callee | Set read at |
|---|---|
| interface requirement | its declared set at the declaring interface instance: a written qualifier (`CallExpr::witness_iface`), else the receiver's first bound that declares it. A requirement's set may name its interface's parameters. |
| generic function | the call's arguments (`instance`, or `dep_args` in a generic body; an extension's parameters first) |
| method of a generic record | the receiver (`r.m()`, `r->m()`, `self`, a derived class through `panic_base_at`, hop by hop) |
| still unbound | itself (a call at the body's own parameters reads the set as written) |

`PanicKnown::Unbound`, a set naming a parameter the call does not bind, adds nothing and is SC116E at the call. A set element nested deeper than `PANIC_SET_DEPTH_MAX` (48, through record arguments and pointees), as in a recursion at ever-larger arguments, makes the function `Diverged`: SC216E at the function, with a note that a declared set bounds it.

Arms at instances: dead arms are the definition's (an arm dead at the definition is dead at every instance). Two typed arms that name one type only at an instance (`catch e: T` beside `catch e: A`, at `T = A`) are SC209E at the instance's use (`InstanceEntry::use_at`) with the instantiation chain notes. PanicEffectChecking checks each live instance once (`InstanceEntry::panic_checked`) over the arms the definition recorded (`FunctionDecl::panic_arms`). A member template of a generic class gets no instance facts, so this check and its dependent results are missing there.

### Gates

SC116E ("... is not yet supported") marks what the mechanism does not yet cover. In a gated body every panicking site is reported, caught or not.

| Gated | Reason |
|---|---|
| a generic closure | |
| a `fn` type whose set names a generic parameter | deduction never reads a `fn` type's effect |
| generators and `async` functions or closures | the coroutine frame has no result slot for an error yet |
| a stored panic result | no language form yet |
| a `for` over a panicking `op in`; a panicking place `op []`; a panicking `op as`; `===` through a panicking `op ==` | the lowering that makes the call runs after PanicLowering, or C++ spells the operator with a non-panic result |
| a panicking requirement whose result names `Self` | its result is spelled outside the witness |
| a pack-expanded variant built or matched at a dependent type | [Generics](Generics.md#instantiation-model) |

In the compiler's own build (an internal regime, [BuildSystem.md](BuildSystem.md#internal-generics-regime)) Sema cannot see that a member call panics, so codegen makes a discarded panic result a C++ error instead ([Unchecked-generic calls](#unchecked-generic-calls)).

The designed generator semantics, not implemented: `next()` returns `Panic<T?, E...>`, so the `for` loop's hidden call is the panicking call; `panic X` writes `Err` into the frame's result slot, finishes the coroutine and suspends for the last time; `async` is the same with `await` as the call site and the task's completion slot as the result.

## Passes

Where each pass sits is fixed by [the Sema pass order](Pipeline.md#sema-pass-order) and [the lowering order](Lowering.md#pass-order).

| Pass | Phase | Role |
|---|---|---|
| OperatorSignatureCheck | C, before ExprTyper | `op panic`'s signature |
| ArmOrderCheck | V | arm after a bare `catch` (SC240E) |
| LoopContextCheck | V | no `return`, `break`, `continue`, `yield` or `panic` in a `finally` body |
| CastTyping | X | asserting downcast flag and SC253W |
| EffectPropagation | Typed barrier | the solve ([The solve](#the-solve)) |
| PanicEffectChecking | C, after the barrier | every rule in [Effect sets](#effect-sets) |
| PanicLowering | L | the rewrite below |
| FinallyLowering | L, after PanicLowering | `finally` as a local record's destructor |
| PanicInstances | M2 | forms each live instance's dependent panic results |
| EnumLayoutLowering / EnumLayoutQuery | L, M2 | tags, sites, payload reads; OPT002R |

`EffectPropagation` is a helper library with the set helpers, `PanicWalk` and `EffectTable`; PanicEffectChecking re-walks each body with sites kept and reports. [Semantic checks](SemanticChecks.md#effect-propagation) places both among the other checks.

### PanicLowering

PanicLowering (`Compiler/Sema/Lower/PanicLowering.k`) turns the effect into ordinary control flow. It runs after ScriptLowering (a script's `main` is an ordinary function by then) and CopyMoveLowering; before FinallyLowering, so every jump and return it makes is an ordinary scope exit there; before LabelLowering, which lowers an arm's `break L` with every other; before CallLowering and SequenceLowering, which meet the held call as an ordinary call. SequenceLowering orders a call whose result is a panic result (a record it otherwise leaves in C++ order), since such a result is always movable.

It reads PanicEffectChecking's facts (`reach`, `is_dead`, `repanic`, the bare binder's type) and goes through EnumLayoutQuery for every tag, site and payload, and through LowerTargets for every C++ name.

#### Signatures

A function whose final set is non-empty gets `FunctionDecl::panic_result = PanicSets::form(T, set)` on every link of its chain in its own TU. `return_type` stays `T`, because an importer's typing reads the declaration after this TU lowered. An override returns its base method's result whatever its own smaller set, since C++ needs one return type through the vtable; a conforming method returns its requirement's result (`_requirement_of`, searching the owner's and its extensions' conformance rows, first match wins), read through the base or row at its arguments (`_through`). A closure's result is on the `ClosureExpr`; a `fn` type's on its canonical node (`FunctionPointerType::panic_result`).

#### Rewrites

```text
return x          ->  return Panic<T, E...>::Ok { value: x }    (bare return / fall-off: Ok of unit)
panic X           ->  build Err<X> with this site's id straight into the target
f(a)              ->  ({ var p = f(a); if !ok(p) { <deliver p> } (p.value as T&&) })
return g()        ->  return fwd(g())     (tail: no try open, g's value type is ours)
a + b, op panics  ->  OperatorLowering::lower_one's call, held like f(a)
```

The held call is a statement expression where the call sat, so evaluation order and short circuits are the tree's: a call under `&&`, `||` or an if-expression arm runs only on its branch. A statement that is just a call holds it without a statement expression. A value that can leave (a returned value, a `panic` payload, a variant field holding a panicking call or a `try`) is bound to a local first, because codegen builds ADT payloads inside C++ lambdas, where a `return` or `goto` would leave the lambda.

#### Delivery

An error goes to the innermost target: the function's return (`return fwd(p)`, or `p` moved when it already has the result type), or the innermost `try`'s slot (fill the slot, `goto` the dispatch). A re-panic forwards the result the error came in, so its original site is kept.

#### Moves

`return x` and `panic x` of a whole local or by-value parameter move it into the return (C++'s implicit move). `panic x` into a `try`'s slot copies, because the local lives on after the `try`. A `panic Big(n)` builds the payload in place; each widening moves it once; a slot moves it in once and out once.

#### `try` / `catch`

Not a `match`: a chain of tag compares and jumps.

- Direct form, when the body is one statement that is, assigns (`x = f()`, `x` pure), returns or binds (`var x = f()`) the only site that reaches the `try`: `{ var p = f(); if ok(p) { <stmt with p.value> } else { <dispatch p> } }`. C++ forbids a `goto` past an initialization into its scope, and a dispatch outside the body's block cannot read a temporary declared in it, which is why only this shape avoids the slot.
- Slot form, everywhere else: a raw-storage slot of type `Panic<void, reach>` that nothing constructs unless a site fails. Each failing site fills it and jumps to the dispatch, which first moves the error into an ordinary local and destroys the slot. Every arm exit (fall through, `return`, `break`, `continue`, `jump!`, re-panic) is then a plain scope exit that destroys the error, so no path leaks the payload, and the success path is unchanged.
- Dispatch: `catch e: E` is `tag == type_id<E>` with `e` a reference to the payload; a bare `catch e` is the final `else`, `e` the error as `Panic<void, L...>`; with no bare arm the leftover is delivered to the next target. Dead arms get no compare. A direct-form `try` dispatches over its `reach`, so result elements the callee never raises are neither caught nor delivered.
- Expression form: the same inside a statement expression, the value in a raw slot of the expression's type that the operand or the arm fills (no `?:`: an arm that leaves is a statement, and the type need not be default-constructible).
- A `try` with C++ exception arms is always the slot form ([C++ exception arms](#c-exception-arms)).

#### `fn` values

A `fn` value of the type's exact set passes as it is. A conversion to a `fn` type with a wider effect has no node in the tree, so EmitIR wraps the value where it is converted ([Codegen](#codegen)).

#### Constructors and destructors

A constructor or destructor never returns a panic result: PanicEffectChecking guarantees nothing can leave one.

#### Dependent results

In a generic body, an arm's test and binding over a dependent set are `PanicOpExpr` `Holds` / `ErrorRef` (EnumLayoutQuery's `panic_holds` / `panic_error_ref`), and an `Err`'s element index is `__kairo_pidx`. A call's result is its callee's at the call's arguments (`panic_call_type`), formed, so a concrete caller holds a concrete canonical `Panic`. The dependent results a body names are recorded on `FunctionDecl::panic_deps`.

### FinallyLowering

A `finally` becomes a local record whose destructor is the body ([Lowering](Lowering.md#passes)). A panic is a return, so C++'s own rule for locals runs `finally` bodies and destructors in LIFO order on a panic's exit with no panic-specific code. Because FinallyLowering runs after PanicLowering, the jumps to a dispatch are ordinary exits to it. A `finally` written after a `try` is a standalone `finally` registered where it stands and run at its block's exit (hence SC211W).

### PanicInstances

In M2 (`_stage_mono_instantiate`; [Generics](Generics.md#monomorphization-sync-point)), `PanicInstances` visits each live instance not yet done (a function, or a generic record for its methods). It substitutes the function's result and every dependent result in `panic_deps` and forms them, so collisions are reported at the instance's use. `InstanceEntry::panic_result` is the predicted canonical result and `InstanceEntry::panic_types` the elements; the layout sweep runs again for their ids.

## Codegen

General emission (tiers, guards, admission, headers) is described in [Codegen](Codegen.md#interfaceemitter); this section is the panic-specific C++ contract.

### Preamble helpers

Written once per C++ TU wherever the `Panic` lang item is defined (InterfaceEmitter; guarded in a header):

| Helper | Purpose |
|---|---|
| `__kairo_tid<E>` | declared, never defined; one explicit specialization per element, `{ value = 0x..u; name }`, written after tier 0 before any use. An element C++ instantiates without a Sema id is a compile error, never tag 0. |
| `__kairo_type_id<E>` | reads `__kairo_tid<E>::value` |
| `__kairo_max_align`, `__kairo_nv<T>`, `__kairo_unit` | the [layout](#layout) |
| `__kairo_pidx<E>` | an element's index in a result's set, at compile time |
| `__kairo_fwd<R, A>(s)` | widening; see below |
| `__kairo_raw<T>` | raw storage for a slot, filled in place and read once by `__kairo_take()` |
| `__kairo_pcall<R>(f, a...)` | a call's result as `R` (forwarded panic result, or plain value as Ok) |
| `__kairo_pset<Panic, T, E...>` | C++-side canonical ordering for dependent sets |
| `__kairo_panic_site` | the [site record](#site-ids) |

The pack constructor of `Panic` takes the site id (`VariantInitExpr::site`, 0 for none) and stores `__kairo_type_id<__type_pack_element<K, E...>>` as the tag; destroy and construct-from find the element by a fold comparing `__kairo_type_id<E>` with the tag.

`__kairo_fwd` is one function template over `P<T, E...>`, selecting with `if constexpr`: the same type is moved; when size, payload offset and trivial copy agree the bytes are `__builtin_bit_cast`; otherwise one case per element of the source that the target holds (`__kairo_fwd_k`), moving the payload into the target's element and copying the site. A source element the target lacks gets no case: it cannot be the tag where `fwd` runs (an override's wider result, for example). C++ instantiates one per (source, target) pair; Sema does not predict the choice.

### Shapes

A panicking function is spelled with its `panic_result` (`CXXSpell::return_spelling`), `noexcept` and `[[nodiscard]]`. Schematic C++ for the slot form. The emitted code reads tags and payloads directly (`__kairo_type_id<E>`, `__kairo_get<K>()`); the example writes them with the equivalent [C++ view](#the-c-view) helpers. `S` is the slot's result type and `FILL` stands for the placement construction into the slot's `__kairo_rbox`:

```kairo
fn config_port(path: string) -> i32 {
    var port: i32
    try { port = parse_port(read_file(path)) }
    catch e: ParseError { port = 8080 }
    catch e: IOError    { log(e.code)  port = 80 }
    return port
}
```

```cpp
int32_t config_port(string path) noexcept {
    int32_t port;
    ::__kairo_raw<Panic<void, IOError, ParseError>> s;   // nothing built on success
    {
        auto p0 = read_file(path);
        if (!::builtin::ok(p0)) { FILL(s, ::__kairo_fwd<S>(p0)); goto catch0; }
        auto p1 = parse_port(::builtin::value(p0));
        if (!::builtin::ok(p1)) { FILL(s, ::__kairo_fwd<S>(p1)); goto catch0; }
        port = ::builtin::value(p1);
    }
    goto done0;
catch0:
    {
        auto e0 = s.__kairo_take();                       // moved out; slot dead
        if (::builtin::is<ParseError>(e0)) { ParseError& e = ::builtin::error<ParseError>(e0); port = 8080; }
        else                               { IOError& e = ::builtin::error<IOError>(e0); log(e.code); port = 80; }
    }                                                     // every arm exit destroys e0
done0:
    return port;
}
```

The expression form and propagation inside an expression use GNU statement expressions `({ ... })`; a `return` inside one returns from the enclosing function. That is why a global initializer cannot hold a panicking site or a `try`: statement expressions are invalid at namespace scope.

The failure test carries no `[[unlikely]]`: `ConditionalStmt` has no slot for it.

### Effect-widening `fn` values

`EmitIR::_fn_effect_value` wraps a `fn` value converted to a `fn` type with a wider set: an owned lambda holding the value and returning `__kairo_pcall<R'>` of the call. A nullable target takes the wrapper as its `T`; a nullable source keeps its null. A witness specialization forwarding to a structural conformer whose result differs from the requirement's converts the same way. A raw `unsafe fn` target cannot hold a lambda and gets no wrapper.

### Generic templates

One C++ template serves every instance of a generic, so a set naming `T` is ordered by C++. CXXSpell spells a `Panic` with a dependent element as `::__kairo_pset<::builtin::types::Panic, T, E...>`. The alias (`InterfaceEmitter::_pset_helpers`) inserts each element into a type list sorted by `__kairo_type_id`, drops repeats, and static_asserts that two different types do not share an id (the C++ side of SC223E), then applies `Panic`. That is Sema's order, so the template's result at `T = A` is the same `Panic<i32, A>` every concrete former names, and repeated elements never make a second C++ type.

Inside such a body nothing only the instance knows is spelled: `catch e: E` is `::builtin::is<E>(p)`, its binding `::builtin::error<E>(p)`, and an `Err` is built at `__kairo_vt<__kairo_pidx<E>(static_cast<R*>(nullptr))>` with payload `typename R::template __kairo_Err_t<E>` (EmitIR `_variant_init`).

Each instance's explicit instantiation spells `InstanceEntry::panic_result` and is preceded by `static_assert(__is_same(<alias at the instance>, <prediction>))`, pinning C++'s order to Sema's. `InstanceEntry::panic_types` are admitted Complete wherever the instance is (EmitPlan), so every element's `__kairo_tid` is written there. A generic interface's witness spells a requirement's result at the specialization's arguments (`EmitWitness::_ret`), and a full specialization orders after the `Panic` template (`EmitPlan::_witness_dep`); see [Witnesses](Witnesses.md#emission).

A C++ host instantiating a generic panicking function at a type no Kairo set was formed with finds no `__kairo_tid` for it.

### Unchecked-generic calls

In the compiler-build internal regime ([BuildSystem.md](BuildSystem.md#internal-generics-regime)) EmitIR spells every member call, operator with a `: type` operand and unbound free call as `(::__kairo_nopanic(), <call>)`. The tag's `operator,` static_asserts that the value is no Panic instance (`__kairo_is_panic`, specialized for the lang item) and yields it, so a panic result that Kairo could not see is a C++ error rather than a dropped error. A construction uses `(::__kairo_nopanic_of<TYPE>(), TYPE(args))` with the builtin comma, so the object is not copied. InterfaceEmitter writes the tag wherever `EmitPlan::needs_nopanic` holds (a function under the internal regime) or `Panic` is defined. Details: [Codegen](Codegen.md#emitir).

## Interop with C++ exceptions

Kairo code never throws, and every Kairo function is `noexcept`. Panics and C++ exceptions meet in two places: a Kairo `try` can catch a C++ exception, and a C++ caller can turn a Kairo panic result into one.

### C++ exception arms

`catch e: cxx::...` whose type is a C++ type outside the body's set is a C++ exception arm (PanicEffectChecking sets `is_cxx`). It is never part of a set, never dead, and matched by C++'s own rules.

PanicLowering builds a `TryCatchStmt` marked `cxx` around the lowered body (emitted by `EmitIR::_cxx_try` as a real `try { ... } catch (T& e) { ... }` inside the still-`noexcept` frame) and places the panic dispatch after it, always in the slot form, since the direct form would put the dispatch inside the C++ `try`. A `goto` out of a C++ `try` block is legal; nothing jumps into one. In that body every non-pure value is bound to a local before an ADT payload is built from it, because payloads are built in `noexcept` lambdas and constructors that would stop the exception before the `try`. After a C++ arm, control jumps past the panic dispatch. `panic e` of a C++ arm's binding panics a copy of the caught object from this site.

Coverage is lexical: a C++ call written anywhere inside the `try` is caught there; a call inside a Kairo callee is caught only if every frame between is `@unwind`, or the program is built with `-funwind` (`LangOptions::unwind`; the per-function rule is `StmtTyping::_stamp_no_unwind`, recorded as `FunctionDecl::no_unwind`). No other C++ call is wrapped. An exception that reaches a `noexcept` frame, or that no arm matches, terminates. A bare `catch` catches panics only.

Without C++ exceptions (`-fno-exceptions`, or a target with no OS, where they default off; `LangOptions::cxx_exceptions`, which FlagTranslator passes to clang), a C++ exception arm is SC220E with an edit removing it and a note at the type. No C++ `try` is emitted then.

A `try` with only C++ arms in the expression form needs a raw slot with no `Panic` involved; `EmitPlan::needs_raw_slot` has the preamble write `__kairo_raw` on its own.

### The C++ view

A C++ caller receives a panicking function's result by value as `[[nodiscard]] Panic<T, E...>`. Class text must be identical in every TU and header and Kairo source has no inline C++, so the API is free templates in `::builtin` (where C++ hosts already reach Kairo's surface, e.g. `::builtin::null`; `kairo::` is the compiler's own C++ and the root of Kairo's std), written by `InterfaceEmitter::_panic_api` after tier 0 wherever the lang item is defined (`__KAIRO_PANIC_API` in a header).

| Name | Meaning | Needs exceptions |
|---|---|---|
| `type_id<E>` | `__kairo_type_id<E>` | no |
| `panic_set<P>` | one partial specialization over `Panic<T, E...>`: `value_type`, `types` (`panic_types<E...>`), `size`, `payload_offset` | no |
| `ok(p)`, `value(p)` | tag is `Ok`; the value | no |
| `is<E>(p)` | `tag == type_id<E>`; constant `false` for an `E` outside the set | no |
| `error<E>(p)` | the element via `__kairo_pidx` / `__kairo_get<K>`, never a byte offset; static_assert for an `E` outside the set | no |
| `site(p)` | `source_site { file, line, col }` of the first site record with `p`'s id; `{nullptr, 0, 0}` for Ok or no record | no |
| `panic_error_base` | `std::exception` with `type`, `site`, `what()`; `catch (const ::builtin::panic_error_base&)` catches any Kairo error | yes |
| `panic_error<E>` | the base plus `E error` | yes |
| `value_or_throw(p)` | the value, or throws `panic_error<E>` for the held `E` (moved out of an rvalue result, copied out of an lvalue one) | yes |

The throwing half is written only where the C++ compiles with exceptions: in a header under `#if __cpp_exceptions`, in a kcc include when the host's LangOptions have them, never in an object's own TU (clang rejects a `throw` at a template's definition, so the text is omitted rather than guarded). A move-only `E` is thrown by move; its `panic_error<E>` has no copy and must be caught by reference.

`what()` is `<message> [<Type> at <file>:<line>:<col>]`, or `<Type> at <file>:<line>:<col>` when the type has no `op panic`. The message comes from the type's own `__kairo_op_panic()` (detected with a `requires` test) or an extension's `__kairo_pmsg<T>::get(e)`, specialized after the extension scope (an extension of a generic target has no single specialization and falls back to the name). `<Type>` is the Kairo name, carried by the `__kairo_tid<E>` specialization; the file is the path in the site record. The location list holds every distinct record with the id, ` | `-separated; with no record the bracket holds the type alone. The string is built once, in the exception's constructor, into one `malloc`'d reference-counted buffer that copies share (a copy never allocates; allocation failure yields `""`).

The site table's bounds are the linker's weak `__start___kairo_panic_sites` / `__stop___kairo_panic_sites` on ELF and `section$start$__DATA$__kairo_psite` on Mach-O (untested). COFF and wasm have no bounds, so `site()` finds nothing there. The bounds are per link unit, so a C++ host linked against a Kairo `--shared` library cannot see the library's sites (the chosen fix registers sites at library load time).

### Headers and kcc

A header (`--emit-headers`) declares each instance homed in its root `extern template`, with the explicit instantiation in exactly one object. A panic result's elements are admitted Complete wherever the result is named (`EmitPlan::_admit_instance`, `_arg_by_value`), so a header declaring `Panic<T, E...> f()` includes every `E`'s header. A kcc `#include "foo.k"` keeps implicit instantiation, because the host may be compiled by a different run than `foo.o` and homes are decided per run; it still writes the `__kairo_tid` specializations of the instances it prunes (IncludeEmitter). See [Interop](Interop.md#exposing-kairo-to-c).
