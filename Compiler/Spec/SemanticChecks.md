# Semantic checks

This document describes the check passes of Sema (stage C) and the EffectPropagation solve at the panic-set barrier. The order they run in, and which half of the barrier each is on, is in [the pass order](Pipeline.md#sema-pass-order). Checks report and poison; they do not stop the pipeline ([Hard stops](Pipeline.md#phase-barriers)). Where a check depends on another pass's output, the dependency is stated with the check.

## Check passes

### AttributeCheck

`Compiler/Sema/Check/AttributeCheck.k`. Every attribute written on a declaration, statement, expression or type either means something where it stands or is an error: unknown (SC145E), misplaced (SC143E), a bad argument (SC144E), or not yet supported (SC116E). Nothing is accepted and silently ignored. It runs before X so its errors appear beside typing's and nothing reads an attribute it rejected (`AttrFacts` treats a bad `@align` as absent). Two other entry points: `register_suppressions` in [expansion](NameResolution.md#expansion), and `run_uses`, which warns at every use of a `@deprecated` declaration (SC146W) and needs X's selections (the overload, constructor or operator).

### TypeCycleCheck

`Compiler/Sema/Check/TypeCycleCheck.k`. Rejects a type whose definition requires its own layout (SC002E): a three-colour DFS over by-value edges only (value members, bases, fixed-array elements, and generic arguments that land by value). Pointer and reference edges are satisfied by a forward declaration and excluded. The grey set is the DFS stack, which is the diagnostic path. A by-value edge to a record that is only ever forward-declared is SC227E. It runs before X, which asks for sizes, and before anything that needs a layout: LayoutPass and EmitPlan's topological sort assume acyclicity.

A generic argument is a by-value edge only when the parameter it binds is reached by value inside the record's own layout. The edge question ("does `Box<X>` hold `X` by value?") is answered from the pattern's fields, which exist before any instance is built, so `class U { var b: Box<U> }` and `struct A { var t: (i32, A) }` (a tuple is the TupleN record) are reported. An instance that is not yet instantiated has an unknown size, never an empty one.

### OperatorSignatureCheck

`Compiler/Sema/Check/OperatorSignatureCheck.k`. Operator declaration rules. It runs before X, because X's derived operators and compound-assignment pairing assume the shapes it rejects:

- `===` and `=` declared at all (neither is overloadable);
- both halves of a compound pair (`op +=` and `op +`);
- a default argument on an operator;
- a comparison not returning `bool`;
- a compound assignment with a result;
- `op ->` not returning a safe `*T` / `*const T` (SC113E);
- `[]` returning nothing or `unsafe *T` (SC114E);
- a member-only operator (`op as`, ...) in an extension;
- `op panic`'s own signature, `const self` and `-> string` (SC201E);
- an operator that shadows one derived from `op <=>` (SC202W).

The place/value rule (`OperatorFacts::is_place`): `[]` returning a safe `*T` / `*const T` is a place operator; any other result makes it a value operator. `.*` and `->*` are not overloadable (the parser rejects the declaration), and a pointer returned by value is not expressible. `MemberTyping::type_subscript` on a Kairo place `op []` yields the pointee of the result as an lvalue (const if the pointer was), and `&a[i]` takes the pointer back; on a value `op []` it yields the result as an rvalue, so `&a[0..1]` is the ordinary address-of-rvalue error. A foreign `operator[]` is taken as declared, an lvalue.

### ClassAllocatorCheck

`Compiler/Sema/Check/ClassAllocatorCheck.k`. A class cannot declare its own allocator (decided 2026-11-02, reaffirmed 2026-11-08): every `op new` and every `static fn op delete` is SC149E at its name, whatever its signature. The parser still declares them under `Allocator`'s member names (`alloc`, `free`, `FunctionDecl::class_alloc_op`) so the head hoists like any member; nothing routes `create` / `destroy` to a class (the former routing and the class's pair in the C++ allocation operators are gone). The same pass reports the destructor's pre-0.2.0 spelling, `fn op delete(self)` (S090E, fix-it to `finally`): the parser keys it as `op finally` and records where `delete` was (`FunctionDecl::old_dtor_at`). Files of the builtin / std library are exempt from S090E until `Lib/` is migrated; remove the exemption then.

This pass checks a form that is to be removed. The design rule is that program source cannot define `op new` / `op delete` (allocation) in any form; passes may synthesize them so emission stays pure, and C++ `new` / `delete` on any Kairo-defined type (classes, structs, ADTs, unions) goes through the Kairo allocator. The class-specific C++ `operator new` / `operator delete` are emitted in C++-facing text ([Codegen](Codegen.md#c-allocation-operators)); the user-written static pair is still accepted by this pass until it is removed. The destructor is a different member, `op finally`; the old `op delete` spelling is an error with a rename fix-it.

### PackChecking

`Compiler/Sema/Check/PackChecking.k`. Where a type pack, a pack parameter and a pack-expanded variant may appear (SC203E to SC207E). It reads only N's names and T's types and runs before X, so an enum it rejects is poisoned before any pattern or construction is typed against its expansions. `@inout` or `@move` on a pack parameter is SC204E with no fix-it: a passing mode has no per-element meaning yet, and dropping it would be a different program.

### Expression typing

The expression typer (X) runs among the checks and is described in [ExprTyping.md](ExprTyping.md#expression-typing).

### ValueCategoryPass

`Compiler/Sema/Check/ValueCategoryPass.k`. X assigns value categories inline, because overload resolution reads each argument's category while it is still typing the call. This pass verifies the assignment is total and ICEs on a typed expression without one.

### ShadowCheck

`Compiler/Sema/Check/ShadowCheck.k`. R048W when a local binding shadows an outer one of the same type, which is what an intended assignment that introduced a new binding looks like. A type change is the point of a rebinding and is not warned. It runs after X and is silent for a binding whose type is still null.

### ShorthandLint

`Compiler/Sema/Check/ShorthandLint.k`. SC226W on `var x = e` whose inferred type is nullable or a pointer with no shorthand saying so. It reads only inferred slots and runs before every lowering, so each declaration it sees was written by the user ([Nullables.md](Nullables.md#passes)).

### Const-self lint (-Wconst-self)

`Compiler/Sema/Check/ParamPassInference.k`, opt-in with `-Wconst-self` (off by default; decided 2026-11-07: it is run over a whole tree first, and whether it becomes the default is decided from that run). Lint only: it stamps nothing and codegen never sees it. SC273W "method 'm' never mutates 'self'; declare it 'const self'" with a `const ` fix-it before `self`, and SC274W "'@inout' parameter 'p' is never mutated; declare it 'const'" with a fix-it that replaces `@inout` by `const`. It reuses ParamPassInference's walk over the lowered tree and its whitelist of read uses ([Lowering.md](Lowering.md#parampassinference); the file's header has the rule): a use not on the list keeps the candidate quiet, so the lint never claims a method or parameter is const-able when it might not be. One more approved use: a call to a method that is itself a candidate (`self.m()`, `self.f.m()`, `p.m()`), an edge decided once the TU is walked, as a greatest fixpoint: every candidate whose own uses were all approved starts const-able, and one with an edge to a method that is not (a failed candidate, or no candidate: another TU, a generic) stops being so until nothing changes. Candidates are the functions SC224W considers (a Kairo body this TU defines, not generic or in a generic, not `virtual` / `override` or in a class with a polymorphic base, not a requirement, FFI, a calling convention, a generator, `async`, `eval`, `main`, `-> !`, `@cold_path`, a const function, a transfer or split constructor, a `where` member or an ADT member), and for a method also not a constructor, `op delete` or an assignment operator, not an out-of-line definition, not in a record or extension that implements an interface, and only in a class, struct or extension. Library files are skipped. The SC274W fix-it edits only the declaration: each call's `&` has to go too. Known gap: a function used as a `fn` value changes type with the fix.

### PatternChecking

`Compiler/Sema/Check/PatternChecking.k`. Usefulness over a pattern matrix (`Compiler/Sema/Check/PatternSpace.k`): SC120E for a non-exhaustive match (statement form too), with a witness; SC121E for an arm that can never match; SC122E for such an alternative. It writes `is_exhaustive`, `covering_arm` and `open_tail` on every `MatchStmt` / `MatchExpr`. A match on a `T?` that answers null first (X's `null_arm`) is checked over its other arms with the column `T`. Integer columns are cut into segments, so ranges can complete a type; flags enums and imported C++ enums are open and need `default`. A match on an `@open` enum that lists every variant is exhaustive (its tail traps, `open_tail`), and a `default` after them is not dead: it is the arm the values no variant names take.

### ReturnPathCheck

`Compiler/Sema/Check/ReturnPathCheck.k`. Structural, not a CFG: SC104E when a value-returning body can reach its closing brace, SC105E for a `-> !` body. It runs after X, because a call ends a path when its type is `!`, and after PatternChecking, because a `match` ends one only when `is_exhaustive` and every arm does. Unknowns (recovery nodes, `inline` blocks, `jump!`, a non-exhaustive match, already SC120E) count as ending the path.

### FnPurityCheck

`Compiler/Sema/Check/FnPurityCheck.k`. `fn f(...) const` and `@pure` against the contract clang gives their C++ attributes (SC200E for every rule). Measured with the bundled clang on a declaration alone (the cross-TU case): `[[gnu::const]]` is LLVM `memory(none) nounwind willreturn nofree nosync`, so an unused call is deleted and repeated calls are merged even across a store; `[[gnu::pure]]` is `memory(read) nounwind willreturn nofree`, so an unused call is deleted and repeats are merged unless a store intervenes; on a `void` function clang ignores both (-Wignored-attributes). clang optimizes on them without looking, so a broken promise miscompiles silently; each rule below is one clause of that contract.

- **The function** (at the declaration, with a fix-it removing the written `const` / `@pure`, `FunctionDecl::purity_at`, where removing it is the fix): it returns a value (not `void`: the attribute would be dropped); it returns at all (not `-> !`: willreturn); it is not `@unwind` (nounwind; under `-funwind` the attribute itself supplies nounwind, which every allowed callee also keeps); it is not `virtual`, `override` or an interface requirement (clang reads the attribute off the declaration a call names, so a call through the base would carry the promise to an override or conformer that never made it); it is not a generator or `async` (the frame is allocated); its result type owns no memory (see "owns" below; making one allocates, nofree).
- **const reads strictly its inputs** (memory(none)): no read or write of a global or static (an `eval` constant is a value, not memory); no dereference (`*p`, `p->x`, `p[i]` on a pointer); no read of a parameter passed by reference: `@inout`, `@move`, `self`, a `const` parameter of record or type-parameter type (all spelled `T&` / `const T&` by CXXSpell). That last rule is needed because clang may move the call across a store to the referenced object. A by-value record parameter is allowed: C++ passes a non-trivial one as a pointer to a fresh caller copy, and clang weakens the promise to `memory(argmem: readwrite)` for any function with such a parameter (measured), so the caller's later stores are never confused with the input. ParamPassInference therefore skips a const function, written or inferred, instead of turning its by-value record parameter into `const T&`. Also no checked downcast (it reads the vtable through the pointer) and no volatile read.
- **@pure writes no memory** (memory(read)): no write to a global or static, no assignment through a pointer, to a field of `self`, or to an `@inout` / `@move` parameter. Reads anywhere are allowed.
- **Both, calls**: only to a const fn, a @pure fn (for @pure), an `eval fn`, a function inference proved const / pure, a C/C++ function clang itself marks `[[gnu::const]]` (for @pure also `[[gnu::pure]]`: read off its clang decl's attributes on any redeclaration, or the Builtin::Context entry for a builtin Kairo minted, `Compiler/Native/KClangPurity.hh`; both reflect OUR invocation, so `abs` is const and `strlen` pure, while `sqrt` and the other errno-setting math functions are neither under `-fmath-errno`; a decl whose header set was released says "none"), or a side-effect-free intrinsic (`__builtin_expect`, `_expect_prob`, `_assume`, `_assume_aligned`, `_unreachable`, `_is_constant_evaluated`, `_target_info`; for @pure also `_compare_mem` and `_prefetch`; never the traps, aborts, memory writers or atomic fences). A user operator (`a + b`, `a[i]`, `a == b`, `x as T` with an `op as` or a converting constructor) is a call and follows the same rule, and so are two calls no node shows: an implicit conversion through an `@implicit op as` (judged at the converted expression; `ExprTyper::check_convertible` records the operator in `SemaContext::implicit_convs`, since neither tree has a node for it: EmitIR spells it as a cast) and a `match` pattern that tests a record against a constant (judged at the pattern, against every `op ==` of the record). Never a function value (a parameter, local or field of function type: nothing says what it calls) and never an interface requirement (the conformer's body decides). An argument omitted for a parameter's default runs the default in the caller, code the body does not show: an error.
- **Both, memory that owns** (nofree; and allocation writes memory): a type "owns" when its copy or its destructor is not trivial (ClassLifecycle's `trivially_copyable` / `trivial_dtor`): a string, a vector, a map, a record holding one, a type that depends on a generic parameter. Not allowed: a local of such a type, a value of one made by a call, a construction, a string literal (`string`), an f-string, a list / set / map / tuple literal, a variant construction or a conversion, or a by-value copy of an owning lvalue into a parameter. Reading a field of a by-value owning parameter is fine (no copy, no destructor runs in the callee on the Itanium ABI).
- **Both, paths that do not return** (willreturn): no `assert`, no `unwrap!`, no asserting downcast; `crash!()` and a call of a `-> !` function are calls to functions that made no promise. `panic` is a return (a tagged result value, no unwinding: [panic.mdx](https://www.kairolang.org/docs/language/panic/)), so a `panic` statement is allowed; what it builds follows the rules above.
- **Both, loops**: `for x in e` only over an integer range, a fixed array or a pack (for const not a slice either: it reads through the slice's pointer). Anything else runs an iterator protocol (a container's, an `op in` generator, C++'s begin/end) whose calls IterLowering has not made yet.
- **Both, other**: no `@cxx::new` / `@cxx::delete` or `@destroy`, no inline C++ (`VerbatimExpr`), no `spawn`, `thread` or `await`.

Decisions and residuals, on purpose: a run-time check the compiler inserts itself (integer division by zero, `-foverflow-checks`) may stop the program inside a const / @pure function; it is allowed, since rejecting it would reject nearly all arithmetic, and the only effect of the promise on it is that a call whose result is unused may be deleted together with its trap. A loop that never ends is C++'s forward-progress rule (clang marks every function `mustprogress`), not this check's. The written promise is checked before the lowerings, so its diagnostics name what the user wrote; a call a lowering (or EmitIR) will make is judged where this check models its source (operators, `op as`, constructors, defaults, for-in, a `match` pattern's `op ==`, an implicit conversion). A by-value owning parameter is destroyed by the callee on the MSVC C++ ABI, not by the caller; no MSVC target is built today. It runs after X (resolved declarations, operand types) and before every lowering, so a lowered call is never mistaken for one the user wrote. With `-finfer-purity` (on by default; `-fno-infer-purity` turns it off) the same rules, silent, decide `FunctionDecl::inferred_purity` for functions that made no promise ([Lowering.md](Lowering.md#purityinference)).

### CallConvCheck

`Compiler/Sema/Check/CallConvCheck.k`. Where `@preserve_most`, `@preserve_all` and `@preserve_none` may stand (SC134E to SC137E): not on code Kairo does not call itself (constructor, destructor, operator, `main`, generator, `async` function, closure, `eval fn`), the same convention across an override set, and every route a call can take must know it. SC150E for an `override` whose C++ parameter types differ from the base's. It needs X's `is_generator` and runs before the lowerings, which mint functions that carry no convention.

### ScopeEscapeCheck

`Compiler/Sema/Check/ScopeEscapeCheck.k`. SC225W when a pointer from an open `AllocatorScope` visibly outlives it: returned, stored to a static or `thread` variable, or stored to a variable declared outside the scope's block (or through a pointer, field or index whose base is one, or a parameter). Intraprocedural and direct only; it stands in until a lifetime analysis exists. It needs X's callees and initializer types and runs before the lowerings, so `@create` is still the call it stands for.

### ControlFlowAnalysis

`Compiler/Sema/Check/ControlFlowAnalysis.k`. The unreachable-code warning, SC003W: one per run of statements after one that ends the path, up to the block's end or a `label!` (a `jump!` target; a label nested in the run ends it too). The divergence rule is ReturnPathCheck's, shared as `FallThrough`, with unknowns the other way round: they fall through, so code that may run is never called dead. It runs before every lowering, so it sees only user code; dead match arms stay PatternChecking's SC121E. A script's top level (`ScriptRules::is_script`) is walked as one block, since it is `main`'s body: a region there is a contiguous run of code items, so a declaration between them (a function, a type, a binding with a constant initializer) is never in it or in its fix-it, and a deferred binding is code. Nothing ScriptLowering mints can warn, since it runs later ([ScriptMode.md](ScriptMode.md#desugaring)).

### JumpLabelCheck script rule

`JumpLabelCheck::run_script_jumps` (`Compiler/Sema/Verify/JumpLabelCheck.k`). In a script, a top-level `jump!` whose path crosses the line of a deferred binding, forward or back, is SC238E at the jump, with notes at the binding and the label. JumpLabelCheck's frame rules run in [V](NameResolution.md#verification); this half runs after X, because which bindings defer is `ScriptRules::defers`, a question of typed, ConstEval-folded initializers, and the same predicate ScriptLowering moves lines by. Every user `label!` / `jump!` is also gated by FeatureGateCheck.

### WhereGuardCheck

`Compiler/Sema/Check/WhereGuardCheck.k`. Judges each `where` dispatch group (formed by [RedeclMerge](TypeResolution.md#redeclaration-merging)). SC228E: a guard on an interface method, an `unsafe` overload or a bodiless declaration; a group with no fallback; members disagreeing on return type, `const self`, `inline`, `-> !` or linkage. SC116E: virtual, `panic`, extension, operator, constructor, out-of-line, forward-declared, generator, `async`, defaulted and variadic members. (`where` on an `eval fn` is EvalUsageChecking's.)

A generic group: RedeclMerge groups generic overloads equal up to their parameters' names (`_alpha_same`, `Substitution::bind_alpha`, which compares value parameters by their declared types' canonicals) when one is guarded. The members must also agree on those names and on their bounds (SC228E), and two unguarded ones are R029E here. A free dispatcher writes its own parameters as each candidate's generic arguments, so a type parameter only the return type mentions and a value parameter forward as they are. Still SC116E: a pack parameter, and on a method a value parameter or a type parameter no parameter's type mentions (the call through `self` writes no arguments, and C++ must deduce them).

Every guard is a run-time `if`, a guard on a type alone (`sizeof T > 8`) included: every candidate is valid for every argument the shared bounds admit. Guards that are conjunctions of integer-parameter-versus-constant comparisons (and bool parameters) are boxes. A box inside an earlier one (or inside the union of earlier one-parameter boxes) is unreachable, a box meeting an earlier one with neither inside the other overlaps, and an empty one never holds: SC229W. Boxes covering every value are a fallback. Each group that passes goes to `SemaContext::where_groups` in dispatch order, for WhereDispatchLowering.

### ClassLifecycle

`Compiler/Sema/Check/ClassLifecycle.k`. Per-record lifecycle facts and the rules about the lifecycle itself; described in [Ownership.md](Ownership.md#copy-and-move). It reads declarations and canonicals, not expression types. The instance is a member of `Sema`, published as `sc->lifecycle`.

### ClosureCaptures

`Compiler/Sema/Check/ClosureCaptures.k`. Decides what every closure captures and how, and records it on the `ClosureExpr` (`cap_decls`, `cap_modes`, `cap_via_ptr`, `cap_uses`): the closure's free automatic bindings (FreeVarScan; statics and globals are named, not captured), by copy with no list (a MOVE type is moved in), by pointer under `|*|` / `|const *|`, as written in a named list, and `self` implicitly as the pointer it is. A binding an enclosing closure holds by pointer is that pointer inside (X's `_capture_view`), so an inner capture copies or converts it. A free binding a named list or `||` leaves out is SC152E at its first use, with a note at its declaration and a fix-it naming it. A named function in a body that uses a local of the enclosing function is SC151E. It needs X and ClassLifecycle (a MOVE capture is moved in). MoveCheck reads each capture as a read where the closure is made and a move capture as a move; FinallyLowering and EmitIR read the rest.

### MoveCheck

`Compiler/Sema/Check/MoveCheck.k`. Decides every move (recorded in `SemaContext::move_sites` for CopyMoveLowering), the pending moves of generic values and forwarding packs, and use after move (SC052E). Its rules are specified in [Ownership.md](Ownership.md#copy-and-move). A `for` binding is a fresh binding each iteration; bindings and field paths under them (`p.a`) are tracked, pointers and `self` are not. Aliases of concrete MOVE values are not tracked.

### AccessCheck

`Compiler/Sema/Resolve/AccessCheck.k`. Enforces `pub` / `priv` / `prot` on what X chose: every `.` / `->` / `::` step of an expression chain, the constructor a construction selected, the fields a named initializer fills, the nested types a type path names, and the member operator an operator expression or a cast selected (reached through its left operand, as a `.` call would be). It also checks top-level declarations reached from another file through a module handle (`geo::area()`) or named as a type, with the same rule (`_check_top`). `priv` is the declaring file's; `prot` the declaring file's module (the tree under the nearest `module.k`, `AST/VisibilityFacts.k`) plus, for a member, the classes deriving from its class; an unmarked declaration is `priv`, or `prot` in a module, except under `-fdefault-visibility=pub` and in builtin and std, which keep the old rule (a class's variables `priv`, the rest `pub`). Violations are SC242E with a fix-it to `pub`, and SC272W chained when a `prot` was refused only because its file has no `module.k`. The emitted C++ keeps `private:` / `protected:` and befriends the class's same-file extension scopes ([Codegen.md](Codegen.md#interfaceemitter)); a `prot` member of a class in a module is `public:`, since C++ cannot say "this module" (`InterfaceEmitter::_cxx_vis`). AccessCheck is the Kairo check; an access error that reaches clang instead is a Kairo failure.

The rule is module-wide. `priv` is the declaring file's (every function in it, free ones included) and the class's own; `prot` adds every class deriving the member's class, from any file. A class's variables default to `priv`, everything else to `pub`. An edge `derives priv Base` / `derives prot Base` narrows a base member reached through the derived class to that class's file (and, for `prot`, its subclasses). Imported C++ members are clang's. `prot` from a subclass in another file follows C++ [class.protected], since the emitted member is `protected:`: an instance member only through an object of the subclass's own kind (`self`, another object of that class, a class deriving it; never a bare `*Base` or a sibling), and a `prot` constructor only as a base initializer. An extension counts as its target's class only in the target's own file. A `priv` or `prot` member implements an interface requirement only for an `impl` declared in its own file, on the record or an `extend` there (`ConformanceChecking::_witness_access_ok`): the witness reaches it as a friend, which only such a declaration makes it.

### InitCheck

`Compiler/Sema/Check/InitCheck.k`. A field's default reads only fields declared before it (SC178E naming both, with a note at the later one): a default keeps the type body's scope, so it may name a sibling bare, and it runs as a C++ default member initializer in declaration order. A static field is never refused. A static's own initializer reads no instance field (SC177E: it runs for no object), and a static with no initializer needs a type with a default (SC179E, as `var x: T` does: it is defined `T R::s{}`). An earlier sibling read in a generic record's default is SC116E, because the thunk's qualified spelling gives the record no template arguments there.

### BaseInitCheck

`Compiler/Sema/Check/BaseInitCheck.k`. `Base::Base(self, args)` (ChainBinding finds a record's constructors under its own name after `::`) is legal only as one of a constructor's leading statements, for a direct or virtual base, with `self` first and nowhere else, each base once; any other call of a constructor by name is SC180E. A base with no default constructor (none declared, deleted, or only a transfer constructor declared) must be initialized by every constructor of a class deriving it (SC181E). EmitIR writes the leading calls as the constructor's mem-initializers (a split constructor's go on its slot constructor), and CtorInitCheck skips them. It needs X's callee bindings.

### CtorInitCheck

`Compiler/Sema/Check/CtorInitCheck.k`. The const-field rule, structural like ReturnPathCheck:

- A const field with no declared initializer is assigned on every path through each constructor, exactly once, never in a loop (SC172E, SC173E). One with an initializer is never assigned; outside a constructor of its own record no const field is assigned at all (SC171E).
- A field with no initializer whose type has no default (`TypeUtil::why_no_default`: `bool`, an enum with payloads, a record with no usable default constructor, an array of those) is required the same way: the constructor's first whole write is its initializer, on every path, and later writes are assignments. Writing part of it (`self.f[i] = e`) before that is an error.
- A one-dimensional, non-const array field of known length may instead be built element by element: `self.f[k] = e` with `k` a constant (ConstEval), every `k` in `0..N-1` exactly once on every path, outside any loop, before `f` or `self` is read (SC176E otherwise). The flow state tracks each element as it tracks a field (`CtorFlow::edef` / `emaybe`); the array counts as assigned when its last element is, and the write that builds an element is marked `AssignOperatorExpr::ci_elem_init` for EmitIR. A write into an element (`self.f[k].x = e`) and an array of arrays build nothing.
- An array field is assigned once: its one whole write in a constructor initializes it, on every path or none, and any other is SC071E (OperatorTyping defers exactly that write to this pass).

The body is read in two parts at the frontier: the last top-level statement that assigns a const or array field whole or, for each other required field (and each array built element by element), the first after which it is assigned on every path, whichever is later. The part before the frontier runs before the object exists, so in it `self` appears only as `self.f = e` or as a read of a field already assigned on every path (SC175E), and it holds no `return` (SC174E). SC116E gates a generic constructor; `try`, `finally`, `inline`, `label!` and `jump!` before the frontier; a static or array local carried across it; and an array field of arrays or of generic length initialized in place. The pass writes the cut (`FunctionDecl::ci_split`, `ci_index`, `ci_slots`, `ci_dense`) for CtorInitLowering and the emitters. ClassLifecycle makes a record with a const field unassignable member by member (SC071E), as C++ does; a transfer constructor with a body still rebuilds it.

### ConformanceChecking

`Compiler/Sema/Check/ConformanceChecking.k`. The rows of every instance the TU names; described in [Interfaces.md](Interfaces.md#conformance). It is the last pass before `Typed`, and it runs before the lowerings because ExtensionLowering emits witness calls against its rows.

### PanicEffectChecking

`Compiler/Sema/Check/PanicEffectChecking.k`. Reads the sets the barrier solved and walks each body again keeping its sites; the rules are in [Panic.md](Panic.md#passes). It needs the solved sets and X's callee bindings. A run with no driver table (`sc->effects` null) solves its own TU here, reading other TUs' sets as they were left.

### EvalUsageChecking

`Compiler/Sema/Check/EvalUsageChecking.k`. What an `eval` context, `eval for` and a body `eval if` may hold, the declaration order of `eval` items, and the string literals C++ reads at compile time; described in [Eval.md](Eval.md#passes). It needs X's callee bindings and `iter_kind`.

### FeatureGateCheck

`Compiler/Sema/Check/FeatureGateCheck.k`. Reports well-typed constructs that have no lowering yet, one SC116E each ("<construct> is not yet supported"). Lowerings carry no diagnostics and run under `--type-check-only`, so an unfinished feature is reported here; the error keeps the schedule out of the lowerings, and a lowering ICE stays an invariant. A gate is removed in the commit that lands its lowering. Gated:

- a ranged `for` whose `iter_kind` is Vector, Set, Map or String;
- `label!` / `jump!` in user code (nothing yet proves a jump crosses no initialization);
- a non-generic ADT enum one of whose lifecycle facts is Unknown (`lifecycle_open`), since EnumLayoutLowering picks its special members from those facts;
- an initializer on an `eval` array-typed field;
- a generic record's field default that reads another field (reported by InitCheck);
- destructuring a struct by field name (`var {a, b} = s`);
- an attribute applied to an expression;
- an `eval for` directly in a module or class body;
- a generic closure (`fn <T>(x: T)`): X types neither its parameters nor a call of it;
- a function or type declared in a body that names a generic parameter of a declaration around it;
- an `extend` in a body.

A plain enum declared generic is SC197E here.

### FlagGates

`Compiler/Sema/Check/FlagGates.k`. The language gate flags and declaration size limits the command line sets (`--no-unsafe`, `--no-fp`, `--no-ffi`, `--no-cxx`, `--no-yield`, `--no-modules`, `--cmax-*`): SC198E for a disabled feature, SC199E for an exceeded limit ([Driver.md](Driver.md#flags)). Only the program's own files are checked, over the tree as written: it runs after X (`--no-fp` reads expression types) and before every lowering.

### PatternCompilation

`Compiler/Sema/Lower/PatternCompilation.k`. Builds the decision tree for every match from PatternChecking's facts and reports (SC116E) the tests it cannot render. It runs last, so an error anywhere above keeps the schedule out of the lowerings. `--print-sema` shows the trees.

## Effect propagation

`Compiler/Sema/Check/EffectPropagation.k` infers the panic set of every function and closure declared with a bare `panic`. What a set contains, and how a call reads its callee's set, is in [Panic.md](Panic.md#effect-sets); this section covers how the pass is driven ([the solve](Panic.md#the-solve) states the fixpoint argument).

The file has three parts:

| Part | Role |
|---|---|
| set helpers | keep a set canonical: each type its canonical, unqualified, once, in the canonical order |
| `PanicWalk` | the walker over one body: every site that may panic, what reaches each enclosing `try`, what leaves the body. PanicEffectChecking reuses it to report. |
| `EffectTable` | the build-wide solve |

The driver owns one `EffectTable` and uses it at the [Typed barrier](Pipeline.md#phase-barriers) of each import group:

1. `reset()` empties it; sets solved for earlier groups stay on their declarations.
2. `add_tu(sc)` for each member that reached `Typed` collects its inferable bodies (`EffectCollect`) and stores each with the empty set, state `Final`, so a query during the solve reads the set as it grows.
3. `solve()` walks every entry with `PanicWalk` and adds what escapes, round after round, until no set grows. With no import cycle, the group is one TU and its callees' sets are already final.

A recursion at ever-larger type arguments (`f<Box<T>>` inside `f<T>`) adds a deeper type each round and would never stop. When an escaping type's nesting passes `PANIC_SET_DEPTH_MAX()`, the function's set is stored as `PanicSetState::Diverged`, skipped by later rounds, read as unknown, and reported by PanicEffectChecking.

A set that cannot be known adds nothing to its caller: a callee in a TU that stopped before `Typed` (never registered), an undefined bare-`panic` prototype, or a gated callee. `effects_of(sc)` returns the driver's table, or null for a run without one, in which case PanicEffectChecking solves the TU alone.
