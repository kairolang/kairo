# Name resolution

This document covers stages E, V and N of Sema: the surface rewrites that run before any name is bound, the structural checks, and the binding of every name head. Their place in the schedule is in [the pass order](Pipeline.md#sema-pass-order).

## Expansion

Stage E (`Sema::_stage_expand`) rewrites the tree so that V, N and T see one canonical form. Its passes need nothing past `Parsed`, except that EvalIfFolding needs I (below). In order:

| Pass | File | Effect |
|---|---|---|
| `@no_warn` scopes | `Compiler/Sema/Check/AttributeCheck.k` (`register_suppressions`) | each `@no_warn(CODE, ...)` declaration registers one quiet scope per code with the TU's sink (`BufferedDiagSink::quiet_in`), so a warning any later pass reports inside the declaration is dropped. The codes are validated later by `AttributeCheck::run`. |
| PrimitiveLimitDesugar | `Compiler/Sema/Expand/PrimitiveLimitDesugar.k` | primitive associated constants become literals |
| AllocSugarDesugar | `Compiler/Sema/Expand/AllocSugarDesugar.k` | `@create` / `@destroy` become calls of `alloc.k`'s `create` / `destroy` |
| EvalIfFolding | `Compiler/Sema/Expand/EvalIfFolding.k` | folds every `eval if` whose condition folds now; defers the rest |
| RequiresDesugar | `Compiler/Sema/Expand/RequiresDesugar.k` | hoists inline generic bounds into `requires_clause` |

Macro expansion is not implemented (`Compiler/Sema/Expand/MacroExpansion.k` is a stub).

### Primitive limits

Every `<primitive>::NAME` that is one of a primitive's associated constants (`i32::MAX`, `f64::NAN`, `u8::BITS`) becomes the literal it denotes, pinned to its type as a suffix would pin it (`IntegerLiteralExpr::pinned_kind`). A float limit carries its limit for EmitIR to spell (`FloatingLiteralExpr::limit`). The pass needs no name lookup: a primitive keyword is in no table, and every value follows from the builtin table and the target. A generic argument such as `Buf<u8::BITS>`, which parses as a type, becomes the `TypeExpr` of a value argument. A limit the type lacks (`f8e4m3::INFINITY`) is R024E with a note; a name that is no limit at all is left for ChainBinding's R024E. A constant wider than 128 bits is SC232E. Running first lets `eval if i32::MAX > N` fold.

### Allocation sugar

`@create` / `@destroy` are the one sugar whose lang items live outside the prelude (see [Lang items](#lang-items)). AllocSugarDesugar mints the callee already bound to the lang item, so N skips it and no later pass meets the attribute. A hand-written `create` with no import is still R020E.

### Eval-if folding

EvalIfFolding ([Eval.md](Eval.md#passes) owns the semantics) replaces every `eval if` whose condition folds by its taken branch and discards the declarations of the others. Each scope it folds in gets a new frozen table without them: a table is replaced, never mutated ([invariant 1](Pipeline.md#invariants)). It runs before V and N, which may not see an untaken branch, and after I, so a condition can read an imported `eval` constant and clang's macro table is joined.

The parse-time `DisambigTable` keeps every branch's names: an importer's `<` disambiguation reads it long before any fold, so a generic in any branch makes the name generic, as an overload would.

Being before T, the pass cannot answer a type fact (`sizeof`, `alignof`, the triviality intrinsics, or an `eval` constant whose initializer reads one). A declaration-scope `eval if` whose condition needs one is deferred; what a deferred `eval if` keeps and refuses is specified in [Eval.md](Eval.md#passes).

V, N, T and RedeclMerge see every branch of a deferred `eval if`; [EvalIfLateFolding](TypeResolution.md#late-eval-if-folding) decides it. A condition that folds at neither point is SC230E. In a function body an `eval if` whose condition does not fold stays `if constexpr`.

### Requires desugaring

RequiresDesugar moves inline bounds (`<T impl I>`, `<T derives B>`) into the declaration's `requires_clause` as `ConstraintExpr` conjuncts and empties the inline lists, so `requires_clause` is the single source of truth for ConstraintExtraction and RedeclMerge.

## Verification

Stage V (`Sema::_stage_verify`) runs structural checks over the expanded tree. They need no names or types, rewrite nothing, and are independent, so all of them run and report. Errors stop the pipeline before N: a structurally illegal tree is not worth resolving.

| Pass | File | Checks | Codes |
|---|---|---|---|
| LoopContextCheck | `Compiler/Sema/Verify/LoopContextCheck.k` | `break` / `continue` outside a loop or naming no enclosing label; a nested label reusing an enclosing one; `finally` outside a function body. `match` is transparent: `break` in an arm targets the enclosing loop. | SC012E, SC013E, SC014E, SC015W, SC239E |
| ArmOrderCheck | `Compiler/Sema/Verify/ArmOrderCheck.k` | a `catch` arm after a bare `catch` in the statement form; two bare `catch` arms. Dead `match` arms are PatternChecking's. | SC008E, SC009W, SC240E |
| JumpLabelCheck | `Compiler/Sema/Verify/JumpLabelCheck.k` | every `jump!` names a `label!` in the same function; no label declared twice. Its script rule runs after X ([SemanticChecks.md](SemanticChecks.md#check-passes)). | SC006E, SC007E |
| PatternBindingCheck | `Compiler/Sema/Verify/PatternBindingCheck.k` | every alternative binds the same names; no name bound twice in one alternative or destructuring | SC010E, SC011E |
| CxxNameCheck | `Compiler/Sema/Verify/CxxNameCheck.k` | every declared name is spellable as a C++ identifier: no C++ keyword (from clang's tables, `Compiler/AST/CxxReservedWords.k`), no reserved pattern, no compiler-reserved prefix | SC004E, SC005W, SC017E |
| ModulePinCheck | `Compiler/Sema/Verify/ModulePinCheck.k` | a bare `module a::b` pin sits where it means something (`pin_allowed`) | R064E |

Unreachable code is not a V check: it needs `!` types and is ControlFlowAnalysis, after X.

## Name resolution

Stage N is `Compiler/Sema/Resolve/NameResolution.k`: two halves in one pass. After it, `NameResolution::fill_lang_items` fills the build's lang items when the TU is the builtin root's (see [Lang items](#lang-items)). N's errors do not stop the pipeline until after T ([Hard stops](Pipeline.md#phase-barriers)).

### Declaration validation, N(a)

N(a) walks the frozen cells:

- links the `Redeclarable` chains of the five type kinds and of modules, retargets the canonical at the definition, and attaches `out_of_line` definitions;
- diagnoses redefinition (R029E) and conflicting kinds;
- populates `sc.well_known`.

A record named with two of `class` / `struct` / `union` across a forward declaration and its definition is R063E at each disagreeing forward declaration, with a fix-it to the reference's keyword (the definition's, else the first forward declaration's); the agreeing links still chain. Bodiless `struct S` / `union U` are forward declarations like `class C`, outside `ffi` too. Two bodies stay R029E. A record that is only ever forward-declared (`decl_only_forward`) is complete nowhere: a by-value edge to it is TypeCycleCheck's SC227E, and a default-built one is reported through `TypeUtil::why_no_default`.

Specializations are skipped: their chains link in T on canonical specialization arguments. Function chains are RedeclMerge's ([Redeclaration merging](TypeResolution.md#redeclaration-merging)).

Modules reopen. Every `module Foo { }` block is a definition, so two defining links are legal in a ModuleDecl ring (`_reopenable`) and a redefinition for the five type kinds. Unqualified lookup treats a module scope as its whole ring. Each block keeps its own table, so after the walk links the rings, `_judge_reopenings` gathers every type-kind name two blocks of one ring share and hands it to `_judge_group` as one cell: a forward declaration in one block chains to its definition in another. This covers same-TU rings only; functions across blocks are RedeclMerge's.

Declarations in sibling branches of one deferred `eval if` are never a redefinition: `_validate_cell` judges each branch's declarations, together with those outside every branch, apart from the other branches' (`sc->eval_branches.exclusive`).

### Binding, N(b)

Every `NamedIdentExpr` head gets `resolved_decl` or `candidate_cell`. The lookup order:

1. the lexical stack of locals, innermost first;
2. `sc->lookup.unqualified(cur_dc)`;
3. the `extend` target (`_ext_target`);
4. clang builtins ([Clang builtins](#clang-builtins));
5. miss: R020E.

A redeclaration chain collapses to its representative; specializations never compete for a name; a genuine overload set goes through whole as a `candidate_cell`.

The lexical stack holds parameters; generic parameters of the enclosing function or type; statement binders (`for`, `catch`, destructuring, `case var n`, context bindings); body `var`s, declared after their initializer; and statement-scope named declarations (`fn inner`, `class Local`, `type X`), declared before their body so recursion binds. A C-style `for var i = ...` scopes `i` to the loop. Statement-scope declarations are in no table; the lexical stack (and T's `ltypes`) own them.

`Self` (lexed as `BiSelf`) in expression position binds to the enclosing type body's declaration: the record, or the `ExtensionDecl`.

An unqualified miss is a miss in every TU, `ffi` importers included: `ffi` imports bring real declarations ([Interop.md](Interop.md#ffi-imports)).

Pattern heads are name uses. A bare identifier in a pattern is never a binder (binders are `var x` / `const x`), so `case MAX`, `case Color::Red` and `case Point(...)` heads bind like any other expression; a bare head that misses is R020E with a note suggesting `var n`. Alternatives share binder declarations: the first alternative of an arm (or of an `A | B` pattern) declares, and each later binder of the same name points at that declaration.

A use of a name declared in more than one branch of a deferred `eval if` is bound to the cell of all of them (`candidate_cell`) until EvalIfLateFolding rebinds it to the survivor.

N does not bind chain steps (ChainBinding), `.Variant` pattern heads (PatternTyping, against the scrutinee's enum), named-initializer field names (X), or attribute arguments.

### Out-of-line bodies of foreign members

An out-of-line body whose owner lives in another TU (`fn S::g` in a Kairo file, `S` from a header) has its `cur_dc` in the owner's scope, keyed by the header TU and parented to the header's file. A plain walk would probe it with this TU's interned keys (a silent wrong member) and never reach the file the definition was written in. The lookup order follows C++ for a member body: locals, then the owner chain (class, enclosing namespaces; it stops before the header's file scope and never reads its overlay) probed by spelling, then the definition's `lexical_dc` through plain `unqualified` (`NameLookup::unqualified_out_of_line`). It is entered only through `_lookup_unqualified` while `_ool_lexical` is set, so every other walk is unchanged. T mirrors it for type heads. Attaching an out-of-line definition (N(a)) and matching it to an overload (RedeclMerge) probe the owner through `MemberLookup::in_scope`, spelled; the constructor test compares spellings, each through its own TU's context.

### Exit test

`NameBindingVerifier` runs at the end of N: no reachable `NamedIdentExpr` survives with both `resolved_decl` and `candidate_cell` null unless it is poisoned.

## Lookup rules

### The explicit-qualifier rule

Kairo has no implicit `this->`. A name that a type scope answers, used from inside a function or closure body, is a member access with the qualifier left off, and is R049E: `self.x` for an instance member, `Self::x` (or the type's own name) for a static one. The exception is a name that denotes a scope (a nested type, a type alias, a nested module), because naming a type is not an access through an object: `Nested { .. }` inside a method means `Self::Nested` and is legal.

A member hit does not end the walk: since a bare name never denotes a member, lookup continues outward past the type scope (enclosing namespaces, the overlay), so a method `open()` can call the imported C `open`. R049E is reported only when nothing outside answers.

N implements it with the `_fn_depth` counter and `_ext_target` (probed after the DC chain); T with `_lookup_in_selfs` for type position. Field defaults and enum variant values keep the type body's scope: `_fn_depth` resets to 0 on entry to every type scope.

### Unqualified member types

A bare nested type, type alias or associated type of the record `Self` denotes at the use is legal but warned, SC243W, with a fix-it inserting `Self::`: nothing at the use says the name is a member. `MemberLookup::is_member_type_of` and `warn_unqualified_member_type` decide it; N calls them in expression position (`Node { .. }`, `Node::make()`) and T in type position, after the name has bound, so each use is warned once and binding is unchanged. Only the innermost `Self` counts: a sibling of an enclosing type seen from a nested one, the type's own name, inherited nested types and nested modules are not warned (`Self::` would name the wrong scope, or a module). The rule applies in any body, so a field type or a method signature in the class body is warned too.

### Clang builtins

A name clang knows as a builtin (`__builtin_expect`, `__builtin_popcount`) is a foreign function the TU did not have to import. `Compiler/Sema/Foreign/BuiltinImport.k` owns them: one build-wide pseudo-header TU (`<kairo-clang-builtins>`, minted through `HeaderIndex::ensure_target`) whose declarations are made on first use from the target's clang `Builtin::Context` (`Compiler/Interop/Clang/BuiltinsSet.k`, owned by `ClangBackend`).

- A builtin resolves only on a total miss in N(b) (`_bind_builtin`), after every Kairo source, so a declaration of the same name always wins. Nothing binds into the builtin TU's table: it is never reachable qualified, through an overlay, or by T.
- Library builtins (`printf`, `memcpy`) and header-dependent ones are not taken: they miss and resolve through their header. Their `__builtin_` forms (`__builtin_memcpy`) are taken, since clang's C++ gate is `isPredefinedLibFunction`, not `isLibFunction`.
- A builtin Kairo cannot type (per-call clang checking, a type only a header declares, an inexpressible parameter) binds to nothing: R057E at the use, poisoned.
- In X a builtin is callable and nothing else. CallTyping's name arm binds the callee without typing it, so reaching `_type_ident` with one is a value use, SC109E. Its integer-constant positions (`FunctionDecl::ffi_ice_mask`) are checked at the Kairo argument, SC108E; only a literal, under unary `-`, `+`, `~` or `!`, counts.
- `CompilerInstance` owns the `BuiltinImport`. The driver calls `startup()` (a join) and then `init` after header indexing and before the first `SemaContext`; `sc->builtins` is set beside `sc->foreign`. A null or unready importer makes every builtin miss into R020E.

### Lang items

Lang items are bound by fid and path. The compiler ships a root named `builtin` (`Lib/builtin`, installed to `<resource-dir>/builtin`; `--builtins-dir` overrides). The driver folds it into every non-builtin TU's import graph and synthesizes one `ImportDecl` with `is_prelude` per TU, equivalent to `import builtin::*`, after parse and before I. `--no-builtins` suppresses the import; `--no-prelude` also keeps the root out of the graph. `WellKnownDecls` lives on the `GlobalDisambigTable` and is filled once per build from the builtin fid between that fid's N and T, by qualified path (`fill_lang_items`): it must precede T there, because T resolves `[T;]` in `Vector(items: const [T;])` through the `Slice` handle. No TU walks its own root by name. The names themselves are defined in `Compiler/AST/LangItems.k` ([invariant 22](Pipeline.md#invariants)).

`@create` / `@destroy` lang items (`Create` / `Destroy`, `alloc.k`'s `create` and `destroy`) are not re-exported by the builtin root. The dependency scanner records each file that writes the sugar and the preprocessor folds `builtin::base::alloc` into its graph; the driver gives that TU a second `is_prelude` ImportDecl, plain with no path segments, whose only effect is the import edge (so `alloc.k` is typed, and its lang items filled, first). Stage I binds no name from it.

`f256` / `f512` (`F256` / `F512`, `num/f256_t.k` and `num/f512_t.k`, with the engine under them) are not re-exported either: four large files every program would otherwise compile (P723). The scanner records each file that spells the type keyword or a literal with the suffix (`DepGraph::f256_users` / `f512_users`), the preprocessor folds the class's file into its graph (`PreProcessor::_add_wide_floats`; never for a builtin file, which imports what it uses), and after the walk the file gets a prelude-shaped wildcard `ImportDecl` of it (`PPWalker::add_implicit_import`): its edge types the class first (its N binds the lang item and `BuiltinType::lang_decl`), and it binds `F256` as the root's re-export did. A macro that expands to the keyword is not seen; such a file needs the type spelled.

### Operators on builtin records

Operators on builtin records (`[T]`, `{T}`, `{K: V}`, `[T;]`, `string`) resolve through the ordinary record path; see [ExprTyping.md](ExprTyping.md#expression-typing).
