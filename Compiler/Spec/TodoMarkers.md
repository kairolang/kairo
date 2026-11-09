# TODO markers

The `TODO(<CATEGORY>)` markers the Stage 0 -> Stage 1 source migration left in `Compiler/`, `Linker/` and `Extras/KaTAR`: one row per category with its meaning, the interim choice, what is still to decide, and its sites. A new marker kind gets a row here when it is introduced.

Markers the self-host migration leaves in the migrated tree, so each kind can be reviewed and decided once. Every marker is `TODO(<CATEGORY>)` (grep-able); `ENUM-OPEN` also carries a sub-category after the colon.

Counts and sites below were filled in by the migration as it ran (its harness has left the repository); `grep -rn "TODO(" Compiler Linker Extras/KaTAR` lists the markers in the tree today.

| Category | Meaning | Interim choice (2026-11-03) | To decide |
|---|---|---|---|
| `TODO(LOOP-PORT)` | Stage 0 `for (; cond; step)` with an empty init, rewritten to `while` / `loop` with the condition at the start or end | Rewritten so behaviour is unchanged (`continue` still runs the step) | Resolved 2026-11-08 (empty-init loops are allowed): Stage 1 parses `for ; c; s { }` (`continue` runs `s`); the 8 sites are empty-init `for` loops again and the markers are gone |
| `TODO(ENUM-OPEN): <sub>` | A closed enum made `@open` because an int-to-enum cast cannot be a checked conversion; `<sub>` says why (flags, wire-format, ...) | `@open` enum; checked conversions everywhere else | 2026-11-08 (adopted on the condition that it be equal or faster): `Support/FlagSet.k` (`FlagSet<E impl FlagBit<U>, U>`) over a CLOSED single-bit enum; -O3 code identical, type-check time equal. ExprFlags and TypeFlags converted (markers gone); later on 2026-11-08 the rest too: BindingShorthand, StringLiteralExpr::StringKind, Immediate::TextPrefixKind, ExprStopKind (now the module-scope ExprStopBit; `ExprParse<T>::ExprStop` is the set), AnnotationPresence, TypeQualFlags (its masks stay variants) and SyncSet; release whole-tree type-check equal. Only TokenKind stays `@open` (hash-probe) |
| `TODO(OP-ASSIGN)` | A Stage 0 `fn op = (...)`. Stage 1 generates `op =` from the transfer constructor, and writing one is an error | A same-type `op =` (deleted, member-wise, or self-check + destroy + the transfer ctor's body) is dropped, because Stage 1 derives the same thing; two differ, see the note in each marker. Token's `token = kind / range / imm` became `set_kind` / `set_range` / `set_imm`, and the call sites were rewritten (a one-shot migration pass). The plain markers (derived `op =` identical) were deleted on 2026-11-07; only the two that record a behaviour difference remain | Resolved 2026-11-08 (`op =` is the one transfer constructor plus a self-check): the compiler matches the spec (probed for COPY, MOVE, NON_TRANSFER; tests Codegen/oop/derived_assign_{copy,move}.k, Sema/Check/derived_assign_rules.k); DiagBuilder's ICE on assigning over an un-emitted builder is spec behaviour; the 4 markers are deleted |
| `TODO(ICE-MACRO)` | Was: `ice_if!` / `ice_fail!` Kairo macros in an added `Support/Ice.k` (patch 006). Dropped 2026-11-03: Stage 0 never had Kairo macros | Inlined at the call site, no macro: `ICE_IF(c, m)` -> `if (c) { kairo::std::ice_fail(m) }`, `ICE_FAIL(m)` -> `kairo::std::ice_fail(m)` (a one-shot migration pass); the message is still built only on the failing path; no marker left in the tree | Nothing open; the row stays so the history reads |
| `TODO(CHAR32-ALIAS)` | `Compiler/Support/Char32.k`, added by patch 007: `pub type char32 = char`, so Stage 0's `char32` (and `char32_t`) keep their spelling (a one-shot migration pass imports it) | Alias in the scratch tree only | Resolved 2026-11-07: the sites say `char` and `Support/Char32.k` is gone |
| `EVAL-HASH` (no marker; the `/* "X" */` beside each value) | A spelling hashed at compile time by `compute_hash::<r"X">()` (DiagID in the generated Registry.k, TokenKind, ~6,350 sites) is written as its integer value (`Scripts/Migration/eval_hash.py`, EvalHash.k's algorithm, checked against Stage 0's own values) | Inlined literal hash; the spelling stays in a comment | Back to a compile-time call once Stage 1's ConstEval evaluates eval fn calls in an enum discriminant; gen_diag.py could also emit the literals itself |
| `TODO(DUCK-GENERIC)` | A generic parameter whose body uses members of T (Stage 0's generics were all C++ templates, duck-typed; an unbounded Stage 1 `<T>` has none, R051E). A one-shot migration pass writes `<T: type>` (the compiler-build internal regime, [BuildSystem.md](BuildSystem.md#internal-generics-regime)) and a marker naming the members, unless its OVERRIDES table gives the site a bound | `<T: type>` at every site below (the OVERRIDES table is empty) | Per site (decided 2026-11-03): a bound `<T impl Iface>` where the members are few and fit an existing or SMALL new interface; `: type` stays for CRTP mixins and large surfaces. Decided 2026-11-08: `-fduck-generics` is off by default, passed only by `build.py` for the compiler's own targets, and not a user feature; sites move to bounds as they are reworked |
| `TODO(RAW-ALLOC)` (the spelling `kairo::std::create` / `kairo::std::destroy` is the marker) | Stage 0's `std::create<T>(a)` / `std::destroy(p)` (lib-helix: C++ new / delete) call Native's `kairo::std::create` / `destroy` (Types.hh, Stage 1 only), the same new / delete on raw pointers (a one-shot migration pass, ~450 sites) | Native new / delete (decision 2026-11-03) | Stage 1.5/2: move to `@create` / `@destroy` with safe pointers, through Kairo's allocator |
| `TODO(STD-STRING)` (the spelling `kairo::std::to_std_string` is the marker) | lib-helix string's `x.std_string()` is Native's `kairo::std::to_std_string(x)`, a std::string copy by bytes and count (a one-shot migration pass, 28 sites) | Native helper (decided 2026-11-03); the reverse is `kairo::std::from_std_string<string>(x)` / `from_sref<string>(r)` (patch 048, 20+ sites in CompilerInstance/FlagTranslator/ForeignInstantiate) | Stage 1.5: drop the std::string uses |
| `TODO(CXX-LVALUE-ARG)` (the Native helper's name is the marker) | A move-only C++ object passed to a C++ `T&` parameter: in Stage 1 passing the variable moves it (no std::move; decided 2026-11-03), so Stage 0's `std::getline(stream, line)` calls Native's `kairo::std::getline(Stream*, Str*)` with `unsafe &` arguments (a one-shot migration pass, 5 sites in Extras/KaTAR) | A Native helper per C++ API | Resolved 2026-11-08: a C++ non-const `T&` parameter IS `@inout x: T`: `&x` binds by reference (derived-to-base too, no move, not viable for `T&&`, preferred over `T*`), a bare variable is SC097E. KTDecompress calls `cxx::std::getline(&f, &line)`; Native's `kairo::std::getline` is gone |
| `TODO(EVAL-DUAL)` (none in the tree today) | Stage 0's `eval fn` was C++ constexpr (compile time AND run time); Stage 1's `eval` is consteval only. A one-shot migration pass drops `eval` from every eval fn / method / constructor / template with a parameter or receiver (33 sites), keeping zero-parameter named constants eval. After eval_hash none of them is needed at compile time, so no eval + run-time twin exists | Plain fn | A site that turns out to need both gets an `eval` twin and a run-time twin with this marker |
| `TODO(CXX-REF)` | A method whose signature must match a C++-defined one returning `T&` (an override of a C++ class method) | `-> __builtin_cxx_lvalue_ref<T>` (spelled `T&` in the emitted C++) | Resolved 2026-11-08: written `-> *T` / `-> *const T`; an override of an imported `T&` method, or an out-of-line definition of an imported member, is `FunctionDecl::cxx_ref_return` and C++ sees `T&` (out-of-line emission itself is still open) |
| `TODO(VECTOR-BOOL)` (the pass, a one-shot migration pass; no marker in the source) | `cxx::std::vector<bool>`'s element is a bit proxy (`std::__bit_reference`) that Kairo cannot test as a condition, `!`, assign from a bool, or convert to bool (~50 sites). Decided 2026-11-03: no language change | `cxx::std::vector<u8>`, one byte per element: writes store `1` / `0` / `(e) as u8`, reads are `(v[i] != 0)` | A Kairo bitset type, or proxy support |
| `TODO(EXPLICIT-BOOL-TEST)` | A truth test on `llvm::Error` / `llvm::Expected`, whose `operator bool` is explicit: Kairo applies no implicit conversion operator (decided 2026-11-04) | `err as bool` / `fref as bool`, kept, each with the marker on the line above (4 sites: HeaderSet.k x2, ClangLocMap.k x1, Linker/API/FS.k x1; patch 047) | Resolved 2026-11-08 (keep `as bool`: an explicit operator bool stays explicit, and Kairo has opt-in @implicit): the 7 markers are deleted, the code stays |
| `TODO(CXX-FUNCTOR)` | A call to an imported C++ object with operator() (`kairo::SmallFunction<64>` and the like): not callable as `f()` from Kairo (SC062E) | Native `kairo::invoke(&f, args...)` through a pointer, since a direct call would move the C++ variable (CXX-LVALUE-ARG); patch 024 | Resolved 2026-11-08 (functors are allowed): `f(args)` on an imported object with operator() resolves like C++ (const / overloads / ref-qualifiers), never moves `f`; ThreadPool calls `_fn()`; Native's `kairo::invoke` is gone |
| `TODO(STRING-FILL)` | Stage 0's `string(c, n)`-style fill: n copies of one byte (`string(' ' as u8, n)`), 8 sites, all in `Compiler/Diagnostic/PrettyConsumer.k` (lines 434, 610, 700, 711, 799, 870, 891, 915 of the migrated file; patch 045) | The builtin string gained `fn string(self, c: u8, n: usize)` (decided 2026-11-04); the migrated call already matches its argument order, so the sites only carried the marker | Resolved 2026-11-07: the constructor is on main and the 8 markers were deleted; no marker left in the tree |
| `TODO(GENERIC-MEMBER-REQUIRES)` | A default constructor added only so an explicitly instantiated generic (`ArenaList<T>`, every member compiled) can default-construct T in a member never called for that T | Add the constructor (decided 2026-11-04, to stay unblocked) | Member-level requirements on generic members, checked at the call (the intended design); then delete these constructors. Sites: AST/Node/Program.k TopLevelItem |
| `TODO` (using-declaration hiding) | An imported C++ class whose `using Base::f;` should hide a base overload, worked around with an explicit `Redeclarable` base (`Compiler/Sema/Foreign/DeclImport.k`) | Explicit base kept | Remove once using-declaration hiding lands |
| `TODO(DEFAULT-VIS)` | Code written when an unmarked declaration was `pub` (a class's variables `priv`); the rule became `priv`, or `prot` under a `module.k`, on 2026-11-08 (`Compiler/AST/VisibilityFacts.k`) | The compiler tree is done: it builds with `-fdefault-visibility=spec` (build.py `tree_visibility_args`), each top-level directory holds a `module.k`, and what another module uses is marked `pub` (2026-11-08). builtin and std keep the old rule by exemption (`VisibilityFacts::_is_lib_tu`, the one marker) | Mark Lib, then delete the exemption (the flag stays for users and tests) |

Related, not markers in the tree:

- **Reference returns in general** (`-> ref!(T)`, by-reference range-for, builder chains) became the pointer form (`-> *T`, `for *x in`, `-> *Self`).
- **`default class X`** (Stage 0 rule-of-five request): dropped.
- **Char literals in byte contexts:** rewritten to u8 literals.
- **Stage 0 map/set sorted iteration** vs Stage 1 insertion order: sorted explicitly at each site; revisit after the self-host.

Stage 0 runtime -> Stage 1 (typecheck phase, 2026-11-03), each exactly the type or call Stage 0 resolved to:

- **Native pointer aliases** `own/obs/opt/oot/view<T>` are `T *` in Native/Types.hh and became `unsafe *T` (`const_*` -> `unsafe *const T`); `cref<T>` (`const T &`) became a plain `T` parameter, which Stage 1 passes by `const T&` for a non-trivially-copyable record it does not mutate (`stage0_types.py`). The INTENT the alias named (owning, observing, nullable, owned-or-null, a view into a buffer) is lost; Stage 1.5 should choose real ownership types (`std::Unique`, `T?`, slices) per alias.
- **lib-helix containers** `vec/map/set/array/list/tuple` became `cxx::std::vector/map/set/...` (the rule: C++ std stays until Stage 1.5). `map`/`set` stay ORDERED, as in Stage 0.
- **`std::print(...)`** ended the line (lib-helix print.hh) unless its last argument was `std::endl`, so it became `io::println`, not `io::print`; multi-argument calls became one f-string (`stage0_io.py`).
- **`char32` / `char32_t`** were `char32`, an alias of Stage 1 `char` in `Support/Char32.k` (see `TODO(CHAR32-ALIAS)`); renamed to `char` on 2026-11-07, once the migration no longer reran.
- **`#[trivially_import(true)]`** (Registry.k) dropped; `Scripts/gen_diag.py` should stop emitting it once Stage 1 builds Registry.k.
- **C `assert(c && "m")`** became `eval if defined!(DEBUG) { if !(c) { kairo::std::ice_fail(m) } }` (`c_assert.py`, 140 sites): <cassert> is compiled out under NDEBUG, which build.k passes to release builds while debug builds get DEBUG, as the Stage 1 build line does.
- **Written compound operators** beside their base (`op |=` next to `op |`, body `a = a | b`) are dropped: Stage 1 derives them (`compound_ops.py`).
- **C++ truth tests** (`if ec`, `!ec` on std::error_code, from C++'s explicit operator bool) are written out: `ec.value() != 0` / `== 0` (`cxx_bool_tests.py`). No language change: conditions are bool (decided 2026-11-03); smart pointers would be `p != null`, optional `has_value()`.
- **std trait `_v` variable templates** (`cxx::std::is_same_v<A, B>`) are `cxx::std::is_same<A, B>::value`, the standard's own definition of each (`std_traits_v.py`): Stage 1 does not import variable templates.
- **Address-of** `&x` is `unsafe &x` (`raw_address_of.py`, ~3,500 sites): Stage 0's `&` made a raw pointer, the tree's pointer types are all raw, and Stage 1's `&x` is safe. Moving to safe pointers is Stage 1.5/2 work with the rest of RAW-ALLOC.
- **Implicit members**: bare member names in methods became `self.x` / `Self::f` (`implicit_self.py`); out-of-line `fn C::m()` got the declared receiver. Members inherited from a base in another file are not seen by the pass and are left to R049E.

`TODO(DUCK-GENERIC)` sites (internal compiler-build regime; pipeline at fcac40b4, members each body reaches through T; 70 sites in 21 files). Constraint candidates: Casting.k's isa / cast / dyn_cast use one STATIC member, `T::classof` (an interface with one static fn per node family); the `*_recovery` helpers read a static `expr_kind` / `stmt_kind` / ... (a field: not expressible as a bound, so `: type`); `NameLookup::_ring` uses one member (`first_decl`). The rest are CRTP mixins or large surfaces:

- Compiler/AST/Context/InstantiationRegistry.k:1154 `_shell<T>` (17): dc_decls, generic_params, init_annotations, init_dc, init_redecl, instantiated, instantiated_from, is_implicit, is_this_definition, kind, ... (17 in all)
- Compiler/AST/Mixin/Redeclarable.k:53 `Redeclarable<T>` (2): _redecl_canonical, _redecl_first
- Compiler/AST/Visitor/ASTWriter.k:258 `ASTWriter<D>` (143): rebuild_dc_decls, rebuild_decl_list, rebuild_expr_list, rebuild_pattern_list, rebuild_stmt_list, rebuild_toplevel_items, rebuild_type_list, transform_align_of_expr, transform_alternation_pattern, transform_anon_initializer_expr, ... (143 in all)
- Compiler/AST/Visitor/RecursiveASTVisitor.k:64 `RecursiveASTVisitor<D>` (405): _rav_dc_nested, dispatch_decl, dispatch_expr, dispatch_pattern, dispatch_stmt, dispatch_type, traverse_align_of_expr, traverse_alternation_pattern, traverse_anon_initializer_expr, traverse_assign_operator_expr, ... (405 in all)
- Compiler/Parser/DeclParse.k:57 `DeclParse<T>` (60): _consume_mode, _index_skip_block, _index_skip_stmt, _index_skip_to_body, _is_terminator_tok, _peek_mode, _pending_close_angle, _reject_mode_binding, _restore_cursor, advance, ... (60 in all)
- Compiler/Parser/ExprParse.k:54 `ExprParse<T>` (48): _consume_mode, _is_terminator_tok, _parse_and_validate_op_spelling, _parse_closure_sig, _parse_generic_args, _parse_match_core, _peek_mode, _pending_close_angle, _reject_mode_binding, _starts_decl_kw, ... (48 in all)
- Compiler/Parser/PatternParse.k:56 `PatternParse<T>` (18): _reject_mode_binding, advance, check, check_peek, ctx, current, current_ptr, diag, enter_depth, exit_depth, ... (18 in all)
- Compiler/Parser/Shared/ImportGrammar.k:70 `ImportGrammar<T>` (8): ig_bump, ig_bump_nl, ig_eof, ig_err, ig_err_remove, ig_kind, ig_peek_kind, ig_tok
- Compiler/Parser/Shared/MacroHeaderGrammar.k:47 `MacroHeaderGrammar<T>` (6): ig_bump, ig_bump_nl, ig_eof, ig_err, ig_kind, ig_tok
- Compiler/Parser/StmtParse.k:76 `StmtParse<T>` (52): _assume_ahead, _attach_trailing, _depth_aborted, _else_attr_kind, _expect_arrow_recover, _finish_if_expr, _is_terminator_tok, _mods_lead_to_fn, _parse_arm_value, _parse_call_args, ... (52 in all)
- Compiler/Parser/TypeParse.k:92 `TypeParse<T>` (32): _consume_mode, _peek_mode, advance, advance_raw, apply_annotations_to_node, apply_quals, at_value_expr_continuation, c_idx, check, check_peek, ... (32 in all)
- Compiler/Sema/Resolve/NameLookup.k:342 `_ring<T>` (1): first_decl
- Compiler/Sema/Type/CallTyping.k:97 `CallTyping<T>` (24): chain_info, check_convertible, conv, ded_scratch, denoted_type, dotted_variant_shape, fail, finish, flow, fn_return_type, ... (24 in all)
- Compiler/Sema/Type/CastTyping.k:87 `CastTyping<T>` (17): arg_info, conv, defer_enum_cast, fail, finish_call_args, fn_return_type, in_unsafe, mark_unknown, ml, needs_bound, ... (17 in all)
- Compiler/Sema/Type/ControlTyping.k:73 `ControlTyping<T>` (33): _enum_of, _head_decl, check_convertible, conv, ded_scratch, denoted_type, discr_enum, dispatch_stmt, fail, flow, ... (33 in all)
- Compiler/Sema/Type/LiteralTyping.k:71 `LiteralTyping<T>` (17): arg_info, check_convertible, conv, dotted_variant_shape, fail, missing_lang_item, ml, needs_bound, null_compared, null_targets, ... (17 in all)
- Compiler/Sema/Type/MemberTyping.k:83 `MemberTyping<T>` (32): arg_info, bound_scopes, call_result_type, cb, check_convertible, ded_scratch, denoted_type, denotes_module, discr_enum, fail, ... (32 in all)
- Compiler/Sema/Type/OperatorTyping.k:112 `OperatorTyping<T>` (31): arg_info, call_result_type, check_convertible, conv, cur_frame, fail, finish, finish_call_args, flow, frames, ... (31 in all)
- Compiler/Sema/Type/PatternTyping.k:81 `PatternTyping<T>` (8): check_convertible, conv, ded_scratch, denoted_type, sc, tu, type_head, type_of
- Compiler/Sema/Type/StmtTyping.k:109 `StmtTyping<T>` (29): arg_info, call_result_type, check_convertible, conv, ded_scratch, discr_enum, dispatch_stmt, fail, flow, frames, ... (29 in all)
- Compiler/AST/Node/Casting.k:86,92,98,104,110,116,122,128,134,140 `cast<T>` (1 each): classof
- Compiler/AST/Node/Casting.k:345,367 `cast_recovery<T>` (1 each): decl_kind
- Compiler/AST/Node/Casting.k:252,275 `cast_recovery<T>` (1 each): expr_kind
- Compiler/AST/Node/Casting.k:437,459 `cast_recovery<T>` (1 each): pattern_kind
- Compiler/AST/Node/Casting.k:299,321 `cast_recovery<T>` (1 each): stmt_kind
- Compiler/AST/Node/Casting.k:391,413 `cast_recovery<T>` (1 each): type_kind
- Compiler/AST/Node/Casting.k:188,196,204,212,220 `dyn_cast<T>` (1 each): classof
- Compiler/AST/Node/Casting.k:352,374 `dyn_cast_recovery<T>` (1 each): decl_kind
- Compiler/AST/Node/Casting.k:259,282 `dyn_cast_recovery<T>` (1 each): expr_kind
- Compiler/AST/Node/Casting.k:444,466 `dyn_cast_recovery<T>` (1 each): pattern_kind
- Compiler/AST/Node/Casting.k:306,328 `dyn_cast_recovery<T>` (1 each): stmt_kind
- Compiler/AST/Node/Casting.k:398,420 `dyn_cast_recovery<T>` (1 each): type_kind
- Compiler/AST/Node/Casting.k:46,54,62,70,78 `isa<T>` (1 each): classof
- Compiler/AST/Node/Casting.k:335,361 `isa_recovery<T>` (1 each): decl_kind
- Compiler/AST/Node/Casting.k:242,269 `isa_recovery<T>` (1 each): expr_kind
- Compiler/AST/Node/Casting.k:427,453 `isa_recovery<T>` (1 each): pattern_kind
- Compiler/AST/Node/Casting.k:289,315 `isa_recovery<T>` (1 each): stmt_kind
- Compiler/AST/Node/Casting.k:381,407 `isa_recovery<T>` (1 each): type_kind

Add a row here whenever a new marker kind is introduced.

## Stage 0 vs Stage 1 semantics (2026-11-03)

Stage 0 and Stage 1 do not mean the same thing everywhere, so the migration is partly a refactor, not only a respelling. Where a mechanical rewrite would compile but change meaning, the change is a numbered patch (or a uniform pass) with a TODO(<CATEGORY>) marker and a row above. Known differences so far: char width (byte vs char32), map/set iteration order, `default class` (rule of five), written vs derived `op =`, copy/move and const& passing, raw vs safe pointers, closed enums, lib-helix runtime helpers vs their Stage 1 replacements.

## Sites (pipeline at b91be5d7, 2026-11-03)

Line numbers are in the migrated tree of that run.

### `TODO(LOOP-PORT)` -- 8 sites, 3 files (a one-shot migration pass)

2026-11-08: all 8 rewritten back to `for ; cond; step { }` (Stage 1 accepts an empty init), the duplicated `step; continue` dropped. The list is the history.

The tree had 8 such loops in 3 files. Three have a `continue`; each became `step; continue`, so the step still runs.

- Compiler/Location/SourceLineTable.k:401, :435, :475, :516, :546
- Compiler/Driver/CompilerInstance.k:2143, :2183 (with `continue`)
- Compiler/Resolution/DirEntry.k:148 (with `continue`)

### `TODO(ENUM-OPEN): <sub>` -- 1 enum left (a one-shot migration pass)

2026-11-08: `Expr::ExprFlags` and `Type::TypeFlags` are closed enums of single bits held in a `FlagSet<E, u8>` (Support/FlagSet.k). Measured on ExprFlags: Base.k's accessors at -O3 are instruction-for-instruction identical; whole-tree type-check of Kairo.k (debug-built compilers, 3 runs each) 31.52 / 31.49 / 31.51 s before, 31.54 / 31.93 / 31.51 s after (medians 31.51 vs 31.54, noise). Later on 2026-11-08, every other `flags` enum is converted the same way, markers deleted: `BindingShorthand`, `StringLiteralExpr::StringKind`, `Immediate::TextPrefixKind` (their `None` / `Plain` variant is the empty set; `== Plain` is `empty()`, `!= Format` is `!equals(FlagSet(Format))`), `ExprStopKind` (moved to module scope as `ExprStopBit`, since an extension cannot name an enum nested in the class template `ExprParse<T>`; `ExprParse<T>::ExprStopKind` aliases it and `ExprParse<T>::ExprStop` is the set, built with `stop_on(A).plus(B)`), `AnnotationPresence`, `TypeQualFlags` (u16; `DataMask` / `CVRMask` / `EffectMask` stay variants, so `has` tests any of a mask and `clear` clears one; the free `| & ~` operators are gone) and `SyncSet` (unused; u32). Whole-tree type-check of Kairo.k, 3 runs each, alternating: release-built (-O3) compilers 7.59 / 7.51 / 7.65 s before, 7.61 / 7.63 / 7.54 s after (Parse.Full median 896 vs 896 ms); ExprStopKind alone in debug-built compilers 30.60 / 30.57 / 30.50 s without, 30.49 / 30.39 / 30.31 s with. Debug-built (-O0) compilers with all of these later conversions against the tree before them: 30.23 / 29.98 / 29.94 s before, 30.63 / 30.67 / 30.69 s after (+2%, spread over Sema: an -O0 FlagSet query is a call, not an `&`).

Sub-categories used:

- `flags`: a bit set; `A | B` is a value no variant names (0 left; all are FlagSet sets now)
- `hash-probe`: the values are spelling hashes, and an arbitrary hash is cast before anyone knows it is a kind (`is_valid_token_kind` switches on the cast value; the lexer makes error tokens from unknown hashes) (1)
  - Compiler/Token/TokenKind.k:24 `TokenKind`

Every other int -> closed enum cast (into Precedence, BuiltinKind, VisibilityKind, ResolveState, TyperState, WellKnownType, PrimLimit, DeclNameKind, DiagID, ...) is now the CHECKED `x as E` (or `x as U as E`). Those values are always variants. DiagID's check is one compare per variant (about a thousand) on each DiagCode construction. It is correct; open it if that cost ever shows. FnModifier is opened in the compiler's own source (patch 002 dropped).

### `TODO(OP-ASSIGN)` -- 20 markers, 12 files (a one-shot migration pass)

2026-11-08: the last four markers (DiagBuilder.k x1, ArenaAllocator.k x3) are deleted; the derived `op =` matches the spec (see the table row).

2026-11-07: every marker below was deleted except the two "not quite the same" ones (Diagnostic/Engine.k, Memory/ArenaAllocator.k), which stay as the record of an open behaviour difference. The list is the history.

Dropped, a deleted copy `op =` (Stage 1 derives none from a deleted transfer constructor):

- Compiler/Token/TokenBuffer.k:69, Compiler/Diagnostic/Engine.k:214, Compiler/Driver/CompilerInstance.k:4564, Compiler/Memory/MappedFileBuffer.k:69, Compiler/Tooling/ParseAPI.k:212, Compiler/Support/TimeReport.k:165, :210, :236, :260, Compiler/Location/SourceLineTable.k:99

Dropped, the body is self-check + destroy + the transfer ctor's body (or member-wise), which is what Stage 1 derives:

- Compiler/Token/TokenBuffer.k:86, Compiler/Tooling/ParseAPI.k:224, Compiler/Memory/MemoryBuffer.k:71, Compiler/Threading/Task.k:60
- Not quite the same, see the marker's note:
  - Compiler/Diagnostic/Engine.k:209: the derived `op =` destroys through the destructor, which ICE-fails on an un-emitted builder, where the written one freed it silently.
  - Compiler/Memory/ArenaAllocator.k:102, :104: a copy AND a move `op =`, both stealing from the source, where Stage 1 has one transfer constructor.

Heterogeneous, so no assignment at all. They became setters and the call sites were rewritten: 23 calls in Compiler/Lexer/Lexer.k (`token = TokenKind::X` -> `token.set_kind(...)`, `= create_source_range(...)` -> `set_range`, `= intern_ident(...)` / an int -> `set_imm`). A `token = other_token` stays an assignment.

- Compiler/Token/Token.k:75 `set_kind`, :80 `set_range`, :85 `set_imm`

### `TODO(CXX-REF)` -- 0 sites

No `-> ref!(T)` method in the tree belongs to a class with a C++ base. The classes that derive clang types (ClangDiagAdapter, KairoHost*, KairoEmit*, HeaderSetPPCallbacks, HeaderSetAction, CodegenPCHAction) return no references. `ref_returns.py` would emit `-> __builtin_cxx_lvalue_ref<T>` plus the marker for such a method. That builtin does not exist yet (grep of Compiler/ and Lib/builtin, 2026-11-03).

### Not markers, but for the same discussion

- **Compile-time string hashing removed** (patch 019): `compute_hash::<r"...">()`'s machinery in Support/EvalHash.k (`EvalStrBuffer`, `compute_length`, the `<eval N>` and `<eval str>` overloads) was removed. Only the Stage 0 constexpr call form used it, and eval_hash.py writes those calls as literals. The run-time compute_hash overloads stay.
- **Builtin string from bytes** (decided 2026-11-03: no builtin change): no Native helper was needed after all. The builtin string already has `string(d: *const u8, l: usize)` and `push_back(c: u8)`, so `string_ptr_ctor.py` writes `string(unsafe ((p as unsafe *const u8) as *const u8), n)` (a raw C pointer is made safe through its own pointee) and `s.push_back(b)` for Stage 0's byte `+=`. TODO(STRING-API) has no sites.
- **Stage 0 `const` on a pointer** parameter or local meant a const pointee (`const p: *u8` = C++ `const u8 *`): `const_pointee.py` writes `p: unsafe *const u8`. A Stage 0 `const` used as an array length or generic argument is `eval` (`const_to_eval.py`; Stage 1 const is a run-time binding).
- **A newline ends a statement** (operators.md). A Stage 0 expression continued onto a line starting with `+ - * &` is two statements in Stage 1, and for numbers that is a silent change, not an error. `leading_unary_ops.py` moves the operator to the end of the line above (245 sites).
- **Integer literals and i32 / f64 overloads**: an untyped literal takes either parameter type exactly, so Command.k's `define<FlagKind::I32>` i32 / f64 overloads tie (SC064E) where C++ picked int. Patch 015 suffixes those literals `i32`.
- **Shadowed roots**: a parameter or local named `cxx` / `kairo` shadows the `cxx::` / `kairo::` paths (R027E). `shadowed_roots.py` renames it `cxx_v` / `kairo_v` within its function.
- **Virtual destructors** (SC056E, decided 2026-11-03): only polymorphic bases need one, and the rule will exempt non-polymorphic bases. Patch 014 gives `virtual fn op finally(self) {}` to DiagConsumer, EmitSink and KairoIncludeSource (they already have virtual methods, so no new vptr). The CRTP mixins and AST node mixins are left as they are.
- **f-strings in generic bodies** (SC080E, decided 2026-11-03): an interpolation in any generic body is checked per instance (a compiler change), so the migration does nothing for it.
- **Builtin names are reserved** (decided 2026-11-03): a user class may not shadow a builtin name, and the clash is a real error (R016E). `Lexer/Immediate.k`'s `BigInt` / `BigFloat` (the same names as `Lib/builtin/num/`) are renamed `ImmBigInt` / `ImmBigFloat` tree-wide by patch 011. This is the permanent port, not a marker. The other half of that problem, one R016E poisoning every generic signature in the importing file, is a compiler error-recovery bug.
- **Reference returns** became RAW pointers, `-> unsafe *T` / `-> unsafe *Self` with `return unsafe &x`, rather than `-> *T` / `&x`. The rest of the migrated tree's pointers are raw, a safe `*T` becomes raw only explicitly (SC028E), and raw_pointers would make a safe return raw on the idempotency rerun anyway. 62 defs in 7 files (DiagBuilder, Command::define, ImportResolver::Builder, CompilerInstance::invocation, FlagValue::as_list, ParsedArgs::get_list, Lexer TextImm get_*). Call sites: `.m` -> `->m`, a value use -> `*f()`.
- **Char literals**: `('a' as u8)` in expressions, `0x61 /* 'a' */` in case patterns (a pattern takes no cast), `r'x'` (C char) -> the integer. 792 sites in 49 files. Stage 1 has no `b'a'`.
- **`typename!(T::X)`** (17 sites, Parser/) is now `T::X` (a one-shot migration pass). Stage 1 resolves a dependent name per instance under -fduck-generics, so nothing is marked.

### Semantic differences hit so far (each handled as above)

- Reference vs copy: Stage 0 `-> ref!(C)` had been turned into `-> Self`, which COPIES, so builder chains labelled a temporary. Now pointers. `var rb = *Builder().cwd(c)` keeps C++'s `auto` copy.
- Raw vs safe pointers: reference returns are `unsafe *T`, not `*T` (above).
- Written vs derived `op =` (OP-ASSIGN): two places where the derived one behaves differently (DiagBuilder, ArenaAllocator).
- Closed enums: `as E` is now a checked conversion (ENUM-OPEN for the enums it cannot be).
- Loop semantics: `continue` in a `for (; c; s)` ran `s` (LOOP-PORT).
- Char width: literals are char32 in Stage 1; byte contexts get `as u8`.
- Stage 0-only spellings with no Stage 1 meaning: `default class` (rule of five, dropped), `fn op in (self)[iter]` and `inline inline` (patch 005). A dead import of a missing module (patch 004) was deleted in main itself.

### CXX-FUNCTOR

2026-11-08: resolved; the three sites call `_fn()` / `task._fn()`.

- Threading/ThreadPool.k enqueue(): `kairo::invoke(unsafe &_fn)` (the single-thread fast path)
- Threading/ThreadPool.k worker loop: `kairo::invoke(unsafe &task._fn)` (2 sites)

### Using-declaration hiding

- Sema/Foreign/DeclImport.k: explicit `Redeclarable` base until using-declaration hiding lands (added 2026-11-07; 1 site).
