# Self-host TODO categories

Markers the self-host migration leaves in the migrated tree, so each kind can be
reviewed and decided once. Every marker is `TODO(<CATEGORY>)` (grep-able);
`ENUM-OPEN` also carries a sub-category after the colon.

Counts and sites are filled in by the migration as it runs
(`python3 selfhost/run.py`); `grep -rn "TODO(" selfhost/scratch` lists them all.

| Category | Meaning | Interim choice (2026-11-03) | To decide |
|---|---|---|---|
| `TODO(LOOP-PORT)` | Stage 0 `for (; cond; step)` with an empty init, rewritten to `while` / `loop` with the condition at the start or end | Rewritten so behaviour is unchanged (`continue` still runs the step) | Whether Stage 1 should accept an empty-init `for`, or the rewrites stay |
| `TODO(ENUM-OPEN): <sub>` | A closed enum made `@open` because an int-to-enum cast cannot be a checked conversion; `<sub>` says why (flags, wire-format, ...) | `@open` enum; checked conversions everywhere else | Per sub-category: keep open, split flags into a bit-set type, or validate |
| `TODO(OP-ASSIGN)` | A Stage 0 `fn op = (...)`. Stage 1 generates `op =` from the transfer constructor, and writing one is an error | A same-type `op =` (deleted, member-wise, or self-check + destroy + the transfer ctor's body) is dropped, because Stage 1 derives the same thing; two differ, see the note in each marker. Token's `token = kind / range / imm` became `set_kind` / `set_range` / `set_imm`, and the call sites were rewritten (`Scripts/Migration/op_assign.py`) | DiagBuilder: derived `op =` destroys through the ICE-ing destructor. ArenaAllocator: a stealing copy AND move `op =` vs one transfer ctor |
| `TODO(CXX-REF)` | A method whose signature must match a C++-defined one returning `T&` (an override of a C++ class method) | `-> __builtin_cxx_lvalue_ref<T>` (spelled `T&` in the emitted C++) | The real spelling of a C++ reference return |
| `TODO(GENERIC-MEMBER-REQUIRES)` | A default constructor added only so an explicitly instantiated generic (`ArenaList<T>`, every member compiled) can default-construct T in a member never called for that T | Add the constructor (user, 2026-11-04: option 3 to stay unblocked) | Member-level requirements on generic members, checked at the call (user: the right decision, P398); then delete these constructors. Sites: AST/Node/Program.k TopLevelItem |

Related, not markers in the tree:

- **Reference returns in general** (`-> ref!(T)`, by-reference range-for,
  builder chains) became the pointer form (`-> *T`, `for *x in`, `-> *Self`).
- **`default class X`** (Stage 0 rule-of-five request): dropped.
- **Char literals in byte contexts:** rewritten to u8 literals.
- **Stage 0 map/set sorted iteration** vs Stage 1 insertion order: sorted
  explicitly at each site (P345), revisit after the self-host.

Add a row here whenever a new marker kind is introduced.

## Stage 0 vs Stage 1 semantics (user, 2026-11-03)

Stage 0 and Stage 1 do not mean the same thing everywhere, so the migration
is partly a refactor, not only a respelling. Where a mechanical rewrite would
compile but change meaning, the change is a numbered patch (or a uniform
pass) with a TODO(<CATEGORY>) marker and a row above. Known differences so
far: char width (byte vs char32), map/set iteration order, `default class`
(rule of five), written vs derived `op =`, copy/move and const& passing,
raw vs safe pointers, closed enums, lib-helix runtime helpers vs their
Stage 1 replacements.

## Sites (pipeline at ce799d3f, 2026-11-03)

Line numbers are in the migrated tree (`selfhost/scratch`) of that run.

### `TODO(LOOP-PORT)` -- 8 sites, 3 files (`Scripts/Migration/empty_init_for.py`)

The brief said 16 sites in 2 files; the tree has 8 loops in 3 files (16 was
likely the diagnostic count). Three have a `continue`; each became
`step; continue`, so the step still runs.

- Compiler/Location/SourceLineTable.k:401, :435, :475, :516, :546
- Compiler/Driver/CompilerInstance.k:2143, :2183 (with `continue`)
- Compiler/Resolution/DirEntry.k:148 (with `continue`)

### `TODO(ENUM-OPEN): <sub>` -- 7 enums (`Scripts/Migration/enum_open.py`)

Sub-categories used:

- `flags`: a bit set; `A | B` is a value no variant names (6)
  - Compiler/AST/Node/Base.k:45 `Expr::ExprFlags`
  - Compiler/AST/Node/Base.k:244 `Type::TypeFlags`
  - Compiler/AST/Node/Statements.k:43 `BindingShorthand`
  - Compiler/AST/Node/PrimaryExpressions.k:836 `StringLiteralExpr::StringKind`
  - Compiler/Lexer/Immediate.k:616 `Immediate::TextPrefixKind`
  - Compiler/Parser/ExprParse.k:79 `ExprStopKind`
- `hash-probe`: the values are spelling hashes, and an arbitrary hash is cast
  before anyone knows it is a kind (`is_valid_token_kind` switches on the
  cast value; the lexer makes error tokens from unknown hashes) (1)
  - Compiler/Token/TokenKind.k:24 `TokenKind`

Every other int -> closed enum cast (into Precedence, BuiltinKind,
VisibilityKind, ResolveState, TyperState, WellKnownType, PrimLimit,
DeclNameKind, DiagID, ...) is now the CHECKED `x as E` (or `x as U as E`).
Those values are always variants. DiagID's check is one compare per variant
(about a thousand) on each DiagCode construction. It is correct; open it if
that cost ever shows. FnModifier is opened in main's own source since
b-inlinecpp (patch 002 dropped).

### `TODO(OP-ASSIGN)` -- 20 markers, 12 files (`Scripts/Migration/op_assign.py`)

Dropped, a deleted copy `op =` (Stage 1 derives none from a deleted
transfer constructor):
- Compiler/Token/TokenBuffer.k:69, Compiler/Diagnostic/Engine.k:214,
  Compiler/Driver/CompilerInstance.k:4564, Compiler/Memory/MappedFileBuffer.k:69,
  Compiler/Tooling/ParseAPI.k:212, Compiler/Support/TimeReport.k:165, :210,
  :236, :260, Compiler/Location/SourceLineTable.k:99

Dropped, the body is self-check + destroy + the transfer ctor's body (or
member-wise), which is what Stage 1 derives:
- Compiler/Token/TokenBuffer.k:86, Compiler/Tooling/ParseAPI.k:224,
  Compiler/Memory/MemoryBuffer.k:71, Compiler/Threading/Task.k:60
- Not quite the same, see the marker's note:
  - Compiler/Diagnostic/Engine.k:209: the derived `op =` destroys through the
    destructor, which ICE-fails on an un-emitted builder, where the written
    one freed it silently.
  - Compiler/Memory/ArenaAllocator.k:102, :104: a copy AND a move `op =`, both
    stealing from the source, where Stage 1 has one transfer constructor.

Heterogeneous, so no assignment at all. They became setters and the call sites
were rewritten: 23 calls in Compiler/Lexer/Lexer.k (`token = TokenKind::X`
-> `token.set_kind(...)`, `= create_source_range(...)` -> `set_range`,
`= intern_ident(...)` / an int -> `set_imm`). A `token = other_token` stays
an assignment.
- Compiler/Token/Token.k:75 `set_kind`, :80 `set_range`, :85 `set_imm`

### `TODO(CXX-REF)` -- 0 sites

No `-> ref!(T)` method in the tree belongs to a class with a C++ base. The
classes that derive clang types (ClangDiagAdapter, KairoHost*, KairoEmit*,
HeaderSetPPCallbacks, HeaderSetAction, CodegenPCHAction) return no
references. `ref_returns.py` would emit `-> __builtin_cxx_lvalue_ref<T>` plus
the marker for such a method. That builtin does not exist yet (grep of
Compiler/ and Lib/builtin, 2026-11-03).

### Not markers, but for the same discussion

- **Reference returns** became RAW pointers, `-> unsafe *T` / `-> unsafe
  *Self` with `return unsafe &x`, rather than `-> *T` / `&x`. The rest of the
  migrated tree's pointers are raw, a safe `*T` becomes raw only explicitly
  (SC028E), and raw_pointers would make a safe return raw on the idempotency
  rerun anyway. 62 defs in 7 files (DiagBuilder, Command::define, ImportResolver::Builder, CompilerInstance::invocation, FlagValue::as_list, ParsedArgs::get_list, Lexer TextImm get_*). Call sites: `.m` -> `->m`, a value use
  -> `*f()`.
- **Char literals**: `('a' as u8)` in expressions, `0x61 /* 'a' */` in case
  patterns (a pattern takes no cast), `r'x'` (C char) -> the integer. 792
  sites in 49 files. Stage 1 has no `b'a'`.
- **`typename!(T::X)`** (17 sites, Parser/) is now `T::X`
  (`Scripts/Migration/typename_macro.py`). Stage 1 resolves a dependent name
  per instance under -fduck-generics, so nothing is marked.

### Semantic differences hit so far (each handled as above)

- Reference vs copy: Stage 0 `-> ref!(C)` had been turned into `-> Self`,
  which COPIES, so builder chains labelled a temporary. Now pointers.
  `var rb = *Builder().cwd(c)` keeps C++'s `auto` copy.
- Raw vs safe pointers: reference returns are `unsafe *T`, not `*T` (above).
- Written vs derived `op =` (OP-ASSIGN): two places where the derived one
  behaves differently (DiagBuilder, ArenaAllocator).
- Closed enums: `as E` is now a checked conversion (ENUM-OPEN for the enums it
  cannot be).
- Loop semantics: `continue` in a `for (; c; s)` ran `s` (LOOP-PORT).
- Char width: literals are char32 in Stage 1; byte contexts get `as u8`.
- Stage 0-only spellings with no Stage 1 meaning: `default class` (rule of
  five, dropped), `fn op in (self)[iter]` and `inline inline` (patch 005). A
  dead import of a missing module (patch 004) was deleted in main itself.
