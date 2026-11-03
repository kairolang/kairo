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
| `TODO(CXX-REF)` | A method whose signature must match a C++-defined one returning `T&` (an override of a C++ class method) | `-> __builtin_cxx_lvalue_ref<T>` (spelled `T&` in the emitted C++) | The real spelling of a C++ reference return |

Related, not markers in the tree:

- **Reference returns in general** (`-> ref!(T)`, by-reference range-for,
  builder chains) became the pointer form (`-> *T`, `for *x in`, `-> *Self`).
- **`default class X`** (Stage 0 rule-of-five request): dropped.
- **Char literals in byte contexts:** rewritten to u8 literals.
- **Stage 0 map/set sorted iteration** vs Stage 1 insertion order: sorted
  explicitly at each site (P345), revisit after the self-host.

Add a row here whenever a new marker kind is introduced.

## Sites (pipeline at 96b07cb0, 2026-11-03)

Line numbers are in the migrated tree (`selfhost/scratch`) of that run.

### `TODO(LOOP-PORT)` -- 8 sites, 3 files (`Scripts/Migration/empty_init_for.py`)

The brief said 16 sites in 2 files; the tree has 8 loops in 3 files (16 was
likely the diagnostic count). Three have a `continue`; each became
`step; continue`, so the step still runs.

- Compiler/Location/SourceLineTable.k:401, :435, :475, :516, :546
- Compiler/Driver/CompilerInstance.k:2142, :2182 (with `continue`)
- Compiler/Resolution/DirEntry.k:148 (with `continue`)

### `TODO(ENUM-OPEN): <sub>` -- 7 enums (`Scripts/Migration/enum_open.py`)

Sub-categories used:

- `flags`: a bit set; `A | B` is a value no variant names (6)
  - Compiler/AST/Node/Base.k:45 `Expr::ExprFlags`
  - Compiler/AST/Node/Base.k:244 `Type::TypeFlags`
  - Compiler/AST/Node/Statements.k:43 `BindingShorthand`
  - Compiler/AST/Node/PrimaryExpressions.k:836 `StringLiteralExpr::StringKind`
  - Compiler/Lexer/Immediate.k:768 `Immediate::TextPrefixKind`
  - Compiler/Parser/ExprParse.k:79 `ExprStopKind`
- `hash-probe`: the values are spelling hashes, and an arbitrary hash is cast
  before anyone knows it is a kind (`is_valid_token_kind` switches on the
  cast value; the lexer makes error tokens from unknown hashes) (1)
  - Compiler/Token/TokenKind.k:24 `TokenKind`

Every other int -> closed enum cast (73 sites, into Precedence, BuiltinKind,
VisibilityKind, ResolveState, TyperState, WellKnownType, PrimLimit,
DeclNameKind, DiagID, ...) is now the CHECKED `x as E` (or `x as U as E`).
Those values are always variants. DiagID's check is one compare per variant
(about a thousand) on each DiagCode construction. It is correct; open it if
that cost ever shows. FnModifier is opened by selfhost patch 002, which
b-inlinecpp supersedes.

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
- **`op =` returning `ref!(T)`** (12 sites: Engine.k:201/217,
  CompilerInstance.k:4326, TimeReport.k x4, Token.k:75/80/85, ParseAPI.k
  :212/:224) are left as `-> Self` (ref_and_mref). Stage 1 generates `op =`
  and an explicit one is an error (classes-lifecycle), so they need their own
  decision. Token's three are heterogeneous assignments (`token = kind`).
- **Char literals**: `('a' as u8)` in expressions, `0x61 /* 'a' */` in case
  patterns (a pattern takes no cast), `r'x'` (C char) -> the integer. 792
  sites in 49 files. Stage 1 has no `b'a'`.
