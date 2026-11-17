# The language server (kals)

`kals` is the Kairo language server: `Analyzer/`, built with
`python3 build.py --debug kals --no-prebuild`. It speaks LSP over
stdin/stdout. This page is the contributor's description and the contract
the code is held to: what runs where, the file formats, the budgets, and
what is built and what is not. The user page is
<https://kairolang.org/docs/toolchain/kals/>.

Each section says whether it is BUILT (the code does this and
`Analyzer/Dev/smoke.py` checks it), PARTLY, or PLANNED.

## Contents

1. [Processes](#1-processes)
2. [Projects: kairo_compile.json](#2-projects-kairo_compilejson)
3. [The snapshot a worker writes](#3-the-snapshot-a-worker-writes)
4. [Requests](#4-requests)
5. [Semantic tokens](#5-semantic-tokens)
6. [Hover](#6-hover)
7. [Inlay hints](#7-inlay-hints)
8. [Completion](#8-completion)
9. [Freshness: what is answered when](#9-freshness-what-is-answered-when)
10. [Scheduling](#10-scheduling)
11. [Latency budget](#11-latency-budget)
12. [Threads](#12-threads)
13. [Cost rules](#13-cost-rules)
14. [Logging and tracing](#14-logging-and-tracing)
15. [C and C++ beside Kairo: the clangd bridge](#15-c-and-c-beside-kairo-the-clangd-bridge)
16. [Compiler hooks](#16-compiler-hooks)
17. [Source conventions](#17-source-conventions)
18. [Testing](#18-testing)
19. [Editors](#19-editors)
20. [Not implemented](#20-not-implemented)

## 1. Processes

BUILT.

```
editor <-- LSP / stdio --> kals (server)  --starts-->  kals --worker  (one compile)
                           buffers, snapshots           type-checks one entry point,
                           no compiler code runs        writes one JSON file, exits
                                          --starts-->  kals --worker --syntax-server
                                          <-- pipes -->  stays up; parses ONE buffer per
                                                        request (no imports, no Sema),
                                                        answers its errors and lexical
                                                        tokens (fallback: --syntax-only,
                                                        a process per pass)
```

The server never runs the compiler in its own address space. A language
server spends its life on half-typed code, which is where a compiler's
remaining crashes are, and a crash must cost one stale answer rather than the
editor's connection. `Analyzer/Server.k` frames messages, keeps the open
buffers, starts workers and looks rows up in their output.
`Analyzer/Index/Worker.k` is the compiler: it type-checks one entry point
with the editor's unsaved buffers laid over the disk, and writes a snapshot.

A worker that crashes or is refused its command line leaves the previous
snapshot in place and is reported (section 14).

**A worker that stays up** (the default;
`initializationOptions.liveCheck: false` or `KALS_LIVE_CHECK=0` turns it off;
section 10, "The live index worker"). A process per analysis cannot
meet the budget of section 11 on a large tree: it re-checks the whole import
graph each time. By default an entry's graph is kept checked in
`kals --worker --index-server`, one process per entry, and a change re-checks
the edited file at once and the files that import it in the background
([IncrementalSema.md](IncrementalSema.md) phase 5). The process boundary and
the snapshot format stay; a process per run stays as the fallback and the
crash boundary.

## 2. Projects: kairo_compile.json

BUILT (`Analyzer/Workspace/CompileCommandsLoader.k`).

A Kairo compile command names an entry point; every other file is reached
through imports. The project file lists entries, and a file belongs to the
entry whose import graph holds it.

```json
{
  "version": 1,
  "entries": [
    { "entry": "src/main.k", "args": ["-I", "include/", "-fimplicit-conv"], "directory": "." }
  ],
  "default_args": ["-I", "include/"]
}
```

| Key | Meaning |
|---|---|
| `entry` | the file `kairo` is given, relative to `directory` |
| `args` | every other argument, as on the command line |
| `directory` | where the command runs, relative to the project file; `.` when omitted |
| `default_args` | flags for a file no entry reaches: it is checked as its own entry with these |

The file is found in the workspace folder or any directory above it. With
none, every file is its own entry with no flags. For this repository
`python3 build.py --debug --emit-compile-json` writes it (one entry per
target, with the flags the build passes); elsewhere it is written by hand
until `build.k` does it.

**Which entry a file belongs to.** An entry that IS the file, or whose last
run read it, answers at once. Otherwise the project's entries are tried one
at a time, nearest in the directory tree first, and only entries that could
reach the file at all: the file must lie under the entry file's directory or
one of its `-I` roots. When every candidate has run and none holds the file,
it is checked as its own entry with `default_args`. A scratch file outside
every root is therefore checked on its own immediately, not after one whole
compile per entry.

**A file of a library.** A file of `Lib/builtin` or `Lib/std` in a source
checkout is reached by no project entry (they import the toolchain's staged
copy), so it is checked as its own entry, and the compiler takes the copy it
lies in as that library's root ([Driver.md](Driver.md#root-discovery)). An
entry inside any library (a named root, or below a pinned `module.k`) is
checked as the module its path names, not as a pathless entry
(`Tooling::ParseAPI::entry_module_path`, shared by the worker and the live
check): the builtin files, the lang items and the library-only rules are found
by that path. The other library is the staged one: a checkout's `Lib/std`
file sees the toolchain's builtin, and definitions into builtin land there.

**What the server adds to an entry's arguments.** `--type-check-only`, and
`--cmax-errors=0` after the entry's own arguments, so every check runs with
no limit on delivered errors and a limit the entry sets does not apply: an
editor shows every error of a file, where the command line stops at twenty.
The index run also adds `--check-past-syntax-errors`, the live worker
`--error-format=basic`. Nothing in the server caps the diagnostics it
publishes. `no_error_limit` in the smoke test.

**Entries have ids.** Each entry gets an `Entry::id` when it is
created, never reused, and a job names its entry by that id, not by its
place in the list. Saving or changing the project file rebuilds the list:
the runs in flight are killed and their results dropped (no entry of the new
list has their id), so a run of the old command never lands in the new
entry that took its index. When a project entry's run turns out to hold a
file that was being checked as its own entry, that ad-hoc entry is retired:
its diagnostics are cleared and its run in flight is killed and dropped.
A run that newly reaches an open buffer read that file from the disk (the
buffer was overlaid only for the files the last run held); when the buffer
differs, it counts as changed after that run and the entry runs again with
it overlaid.

## 3. The snapshot a worker writes

BUILT.

```
kals --worker <out.json> [--cwd <dir>] [--root <dir>] [--overlay <real> <tmp>]... -- <kairo arguments>
```

`--overlay real tmp` makes the compile read `tmp`'s bytes wherever it would
read `real` (the entry or an import). `--root` names the directory whose
files are indexed; above 96 files in the import graph only the overlaid
buffers are (`"wide": false`), because a snapshot of a large tree on every
pause in typing is mostly never asked about.

`--progress <file>` makes the worker write the number of files Sema has
finished checking into `<file>` as it goes (section 14).

One object: `ok`, `files`, `unchecked`, `partial`, `diagnostics`, `deps`,
`wide`, `tables` (with `tablesAll`, and from the live worker `tablesSeq`),
`cxx_flags`, `c_flags`. The member names are `SK_*` in `Index/Snapshot.k`, for the writers
and the server's reader alike; a row that is an LSP object (an outline
symbol, an inlay hint, a completion item, a diagnostic, a fix's edit) keeps
the LSP names (`K_*`, `Protocol.k`). The worker's words are `WA_*` in
`Analyzer/WorkerArgs.k`. `unchecked` and `partial` list the files a graph with syntax errors
left unchecked, or checked without the bodies the errors are in (section 9). Every position is
already an LSP position (0-based line, UTF-16 column); the server converts
nothing on the way out.

| Member of a `files` entry | Content |
|---|---|
| `path` | the file |
| `tokens` | semantic tokens, LSP's relative five-integer encoding |
| `refs` | `[line, char, len, declFile, declLine, declChar, declLen, hover, isDecl, typeFile, typeLine, typeChar, typeLen, kind]` per name use and declaration, **sorted by position** (the server binary-searches them); `declFile`, `typeFile` and `hover` index the arrays below; `kind` is the token type of what the name refers to |
| `files` | paths `declFile` / `typeFile` index |
| `hovers` | markdown `hover` indexes |
| `bases` | `[line, char, len, baseFile, baseLine, baseChar, baseLen, name, baseName, kind, baseKind]` per derive/implement edge, and per method that has the name of a method of a base |
| `links` | `[line, char, len, path]` per import that resolved to a file: a Kairo import's module path, or an ffi import's header string and the header clang resolved (the import's `resolved_fid`, kept only when its path ends in the spelling; a header clang did not find has no link) |
| `symbols` | the outline, flat in source order; the server nests by range |
| `inlays` | inlay hints (section 7) |
| `items` | completion items, present when the buffer held the completion marker |
| `scope`, `sfiles`, `sees` | what a bare name reaches through the file's imports, the paths those rows index, and the files whose `extend` blocks the file sees, in the order of the paths' hashes (section 8) |
| `macros` | `[line, char, len, expansion, endLine, endChar]` per macro invocation in the file, the outermost only (a nested invocation is part of its parent's text); `len` is the invocation's length on its first line, `endLine`/`endChar` where it ends |

`tables` is one declaration table per Kairo file of the graph, whatever
the width (section 8): what completion is answered from. `cxx_flags` and
`c_flags` are the compile's driver words for a C++ and a C source (what
kcc gives one: the clangd bridge's flags, and the include directories an
`ffi import "..."` is completed from).

A `diagnostics` entry is `{ path, diag, fixes }`: `diag` is an LSP Diagnostic
(the primary label's range, notes as `relatedInformation`), `fixes` are the
compiler's fix-its as `{ title, edits: [{ path, range, newText }] }`.

A loop's binders (`for x in xs`, `for var (k, const v) in m`) and a
pattern's (`case var n`, `case Some(x)`) are declarations with rows
(`visit_ranged_for_stmt`, `visit_binding_pattern`), because the visitor does
not dispatch a binder's declaration: a loop variable has a hover, a
declaration among its references, and is a local to complete.

Two `refs` rows name the same thing when their declaration location is
equal. A constructor's row points at its type, so a class and its
constructors are one symbol to rename, highlight and find.

**The header job** (section 15).

```
kals --worker <out.json> --cwd <project> --as-module [--overlay <real> <tmp>]... -- <default_args> --emit-headers <project>/.kairo/clangd --emit-headers-layout <file.k>
```

`--as-module` checks the file as the module the driver names it
(`ParseOptions::as_module`; a pathless entry has no header), so the
compiler's own `--emit-headers` writes its header. The snapshot adds
`header` (the path under the cache directory, `<module path>.hh`) and
`errors`; `deps` is what the bridge watches.

**The syntax-only worker.**

```
kals --worker <out.json> --syntax-only <file> [--overlay <real> <tmp>]... -- <file>
```

`kfmt`'s single-file path: `preprocess_one` + `parse_one` on `<file>` with
its buffer overlaid, one thread (`--threads=1`), no import resolved, nothing
checked. Output: `{ ok, parsed, unsure, diagnostics, tokens }`; `diagnostics` as
above but only what the parser reports (`S<n>` codes, not `SC<n>`) and
fatals; `parsed` is false when one of them is an error; `unsure` says `parsed` holds of the file ALONE: it invokes a macro no
file of its own declares (an R013E the pass does not keep; the builtin
library's macros are known to it), whose expansion is another file's
text and may not parse where it is expanded; `tokens` is the
semantic-token encoding of the raw lex alone (keywords, comments, strings,
numbers, primitive type names; no identifier, and an f-string is one string).
The pass runs with NO error limit (`DiagEngine::set_error_limit(0)`): a
file parsed alone reports every import it cannot resolve, which are not
kept, and after `--max-errors` of them (20) the engine delivered nothing
more, the parser's errors included, and the pass would say `parsed` of any
broken file with twenty imports, which is most files of a real project: such
a buffer would be handed to the live worker to keep (a whole check per
broken keystroke) and never take the "does not parse" rows of sections 9 and
10. `many_imports` in the smoke test.

**Macro expansions** (`macros`). A token the preprocessor produced is
`TkMacroExpand` and carries an invocation's range in this file: the
outermost one's, or, for what an invocation in its arguments produced, that
inner invocation's, which lies inside it. A run of such tokens whose ranges
overlap is one invocation, spanning their union. Each token is
spelled through `TokenText::resolve`, as `--dump-preprocessed` spells it,
with the macro body's own line breaks (indented by brace depth) and no space
inside `a.b`, `a::b`, `f(x)`, `v[i]` or before `,` and `;` (the lexer keeps
no inter-token whitespace; `--dump-preprocessed` puts one space everywhere).

Ranges come from name tokens, never from node ranges, which are not faithful
to the text. File text is read as raw bytes: `SourceManager::get_text`
mangles non-ASCII.

## 4. Requests

BUILT unless marked.

| Request | Answered from |
|---|---|
| `publishDiagnostics` | per buffer, the newest of its syntax-only pass and its entry's last run (section 9) |
| `codeAction` | the last run's fix-its; on a macro invocation also **View expanded macro** (`quickfix`, `command: kairo.showMacroExpansion`, `arguments: [uri, range, expansion]`; the kairo-lsp VS Code extension shows the text read-only beside the editor) and **Expand macro here** (`refactor.inline`, an edit replacing the invocation with its expansion, which works in any client). The macro actions carry positions, so they come only from an index of the current text |
| `semanticTokens/full`, `/full/delta`, `/range`, `documentSymbol`, `inlayHint`, `documentLink`, `codeLens` | the file's row arrays. A delta is one edit: what lies between the longest common prefix and suffix of the last array sent for that buffer and the new one, cut on token boundaries |
| `definition`, `declaration`, `typeDefinition`, `hover`, `documentHighlight`, `references`, `rename`, `prepareRename` | `refs`; `definition` and `declaration` where no ref row answers but a link covers the position answer the link's file at 0:0 (an import's module path, an ffi header string, as clangd on an `#include`); `hover` on a macro invocation is `macros` instead: **Expands to** and the expansion in a `kairo` code block |
| `implementation`, `prepareTypeHierarchy`, `typeHierarchy/supertypes`, `/subtypes` | `bases` |
| `prepareCallHierarchy`, `callHierarchy/incomingCalls`, `/outgoingCalls` | `refs` whose target is a function, grouped by the function symbol whose range holds the use |
| `workspace/symbol` | every snapshot's `symbols` |
| `completion`, `completionItem/resolve` | section 8 |
| `signatureHelp` | the buffer's text (which call the cursor is in) plus every `fn name(` among the snapshots' hover texts, so all overloads are listed; for a function no snapshot has seen used, `fn name(` in the text of the files the entry reads |
| `foldingRange`, `selectionRange`, `onTypeFormatting` | the buffer's text alone (`Analyzer/TextScan.k`): exact for the current keystroke, and they work on a buffer that does not parse. On-type formatting moves a typed `}` that is first on its line to the column of the line that opened its block |
| `formatting`, `rangeFormatting` | `kfmt --stdout`, found beside `kals` and then on `PATH`; the answer is the smallest whole-line edit, and for a range only when that edit lies inside it |
| `$/cancelRequest` | a request still waiting for a snapshot is answered `RequestCancelled` (-32800) and never computed; a completion still running is disowned |
| `$/kals/analysed` (server to client) | one per finished run: `{ entry, revision, current, exitCode }`, sent after the run's diagnostics. `revision == current` means the server has caught up with the text |
| `$/kals/text` (debug request) | `{ textDocument }` -> `{ hash, size, lines, version }` of the server's copy of the buffer (`hash`: FNV-1a 64 of its bytes, as a decimal string); what a test compares its own copy with after incremental edits |
| `window/workDoneProgress/create`, `$/progress` (server to client) | section 14 |

**Generate interface for 'Name'** (`refactor.extract`):
with the cursor on a class or struct name where it is declared, one edit
inserts `pub interface IName { ... }` above the type (above its `///` and
attribute lines) and adds `impl IName` to the type's header (`, IName`
after an existing `impl` clause; the docs spell conformance
`class Name impl I`, classes-interfaces). The interface lists every `pub`
instance method declared in the body with its signature as written up to
the body (generics, modes, return type, `requires`, `panic(E)`), one line
per method, each with its `///` lines. Left out: constructors (`fn Name`),
the destructor (`fn op finally`), `static` and non-`pub` methods, and
extension methods (outside the body). A method declared with a bare
`panic` is left out with a comment line: a requirement must name its set
(interfaces-requirements). `IName` already declared in the buffer or any
file of the entry's snapshot: `NameInterface`. Planned from the buffer's
text (`TextScan::interface_for`), offered only when the type has at least
one such method (an empty interface is an error).

PLANNED: other code actions (section 20).

There are no run or debug lenses and no test explorer (running is the build
tool's), and no view of the compiler's generated C++ as if it were Kairo.

## 5. Semantic tokens

BUILT.

Types: the standard set plus `selfKeyword`, `builtinType`, `typeAlias`,
`union`. Modifiers: the standard set plus

| Modifier | On | Clients draw it as |
|---|---|---|
| `overloaded` | a call whose callee shares its name with another declaration in its scope or is constrained by a `requires` clause, and a user-defined operator (the token is then of type `operator`) | underline |
| `dispatched` | a call to a function that dispatches at run time through `where` guards | underline, italic |
| `extension` | a call to a method or operator an `extend` block supplies | italic (an extension operator is NOT also `overloaded`) |
| `ffi` | a name declared in C or C++ | |
| `constant` | a `const` / `eval` binding | |
| `constructor` | a constructor's name, whose type is that of its class | |
| `mutates` | the `&` of a call argument through which the call may write | bold |
| `inout` | the `&` of a call argument bound to an `@inout` parameter or a C++ `T&` | bold, green |
| `pointer` | the `&` of a call argument bound to a pointer parameter (`*T`, `unsafe *T`, `*const T`, and each behind `?`) | bold; the colour comes from `unsafe` / `readonly` beside it |

A primitive (`i32`, `bool`, `usize`) and a type of the builtin library (`string`) are the standard `keyword` type with `defaultLibrary`, so a client needs no rule for them; `builtinType` is only `Self`.

The legend is `token_type_names()` / `token_modifier_names()` in
`Analyzer/Index/Legend.k`; the server advertises exactly those.

Identifiers are classified by the walk over the checked tree; keywords,
literals and comments by a second lex of the file. **A buffer that does not
parse** is answered from its syntax-only pass (section 3) when that pass saw
the current text and the entry has no index of it: keywords, comments,
strings and numbers at their current positions, identifiers left to the
editor's grammar. Once the text parses and its run lands, the full tokens
return. An identifier the tree
did not resolve gets no token and is left to the editor's grammar. An
f-string is one token to the lexer; the indexer splits it so the text is a
string and each `{...}` is code (names from the walk, numbers, operators).

### The style table

PARTIAL (smoke.py `styles`, `cxx_refs`, `macro_styles`). What each style MEANS. A style is
never reused for a second meaning; the server sends modifiers, and the three
clients map them to exactly these styles.

| Style | Meaning | Modifier |
|---|---|---|
| underline, no italic | call to an overloaded Kairo function or operator | `overloaded` |
| underline + italic | call dispatched at run time through `where` / `requires` | `dispatched` |
| italic, no underline | call to an extension method, or to a function defined in C or C++ | `extension`, `ffi` |
| bold | call to an unsafe function; an unsafe operation (`unsafe &x`, an unsafe cast, an unsafe pointer dereference); the `unsafe` keyword | `unsafe` |
| bold, on the `&` only | the `&` of `f(&x)`: this call may mutate `x` (an `@inout` argument or the address of a mutable passed to a `*T`); also the `[` of a subscript that calls `op []=` | `mutates` |
| bold, green (#2EA043), on the `&` only | `f(&x)` binds `x` to an `@inout` parameter or a C++ `T&` | `operator` + `inout` + `mutates` |
| bold, the theme's operator colour, on the `&` only | `f(&x)` passes a pointer to a `*T` (or `*T?`) parameter | `operator` + `pointer` (+ `mutates` when `x` is a writable place) |
| bold, purple (#B44FD6), on the `&` only | `f(unsafe &x)` passes a raw pointer to an `unsafe *T` parameter (a C++ `T*`) | `operator` + `pointer` + `unsafe` |
| bold, grey-blue (#7088A8), on the `&` only | `f(&x)` passes a pointer to a `*const T` parameter: the call cannot write `x` | `operator` + `pointer` + `readonly`, never `mutates` |
| bold italic, purple (#B44FD6), on the `&` only | `f(unsafe &x)` to an `unsafe *const T` parameter (a C++ `const T*`) | `operator` + `pointer` + `unsafe` + `readonly` |
| amber (#D4900A), name and `!` as one token | a macro: an invocation (`name!(...)`, `name!`, `a::name!`), a definition's name, a macro imported by name | `macro`; a definition adds `declaration` + `definition`, a builtin macro or `name!` intrinsic adds `defaultLibrary` |
| enum-variant colour | constants and `eval` values, like enum variants | `constant` |
| strikethrough | a use of something deprecated | `deprecated` |
| dimmed | unused variables, parameters and imports; code an `eval if` removed | `unused`, `inactive` |
| dimmed from the move onward | a variable after it was passed to `@move` | `moved` |
| a second shade of the variable colour | `var` (mutable) against `const` and immutable bindings | `mutable` |
| dotted underline, off by default | a call that can panic (non-empty solved panic set) | `panics` (`kairo.highlight.panics`) |
| keyword colour | primitive types and the builtin library's types (`string`) | standard `keyword` + `defaultLibrary`; `Self` alone is `builtinType` |
| their current colour, unchanged | `self` and `Self` | `selfKeyword` |

Precedence, where two apply to one token:

1. `dispatched` beats `overloaded`: underline + italic means dispatch and
   nothing else.
2. For an extension or C/C++ call, italic wins and `overloaded` is not
   drawn: overloading is the norm in C++ and says little there, and drawing
   it would collide with rule 1.
3. `unsafe` (bold) and `deprecated` (strikethrough) combine with anything.
   On the `&` of a call argument the parameter's kind decides the colour:
   `pointer` + `unsafe` (purple) beats `pointer` + `readonly` (grey-blue),
   and `inout` (green) is never sent with `pointer`. `mutates` adds bold
   only, so it never overrides those colours.
4. `inactive` hides every other style; `moved` and `unused` dim on top of
   the token's colour.

Editors that cannot draw a style (a dotted underline, a second shade) fall
back to nothing for it, never to another row's style.

As built (server):

- The `&` of a call argument (`IndexWalker::mark_amps_`) becomes an
  `operator` token tagged by the parameter it binds to. Arguments are
  matched to parameters through the call's `arg_map` (so a named or
  reordered argument is tagged by its own parameter, and `self` is never an
  argument); a call with no map falls back to position. The `&` is found
  under a named argument's label, parentheses and `unsafe`, so `&x`,
  `&a.b`, `&v[i]` and `unsafe &x` are all tagged. The parameter's
  canonical type is read (an alias of a pointer is a pointer; a dependent
  type is read as written):
  - an `@inout` parameter, an `@inout` marker
    (`UnaryOperatorExpr::is_mode_marker`) or a C++ `T&`: `inout` +
    `mutates`;
  - `*T` (or `*T?`): `pointer`, plus `mutates` unless the `&e` is typed
    `*const T` or takes the address of a binding that is not mutable;
  - `unsafe *T` (a C++ `T*`): `pointer` + `unsafe`;
  - `*const T`: `pointer` + `readonly`, never `mutates`;
  - `unsafe *const T` (a C++ `const T*`): `pointer` + `unsafe` + `readonly`.
  Not tagged: a C++ `const T&` or `T&&` parameter and a `@move` parameter
  (their arguments take no `&`), the arguments of a pack parameter or of a
  C variadic's `...`, and any call with no selected callee (unresolved or
  ambiguous). Also `mutates` alone: the `[` of a subscript that calls a
  split type's place form, `op []=`: the use writes the element.
- `macro`: an identifier followed directly by `!` (not `!=`), as the
  preprocessor detects an invocation, is ONE token covering the name and
  the `!`. It is read from the raw lex in both the run's tokens and the
  syntax-only pass's (`macro_token_len` in `Analyzer/Index/Tokens.k`), so it
  does not change when the buffer stops parsing; it wins over the walk's
  classification (an import's `lib::name!` segment is otherwise a
  `namespace`). After `macro` it carries `declaration` + `definition`; an
  unqualified name in `LangMacros::known` / `LangIntrinsics::known` (the
  names the preprocessor reserves) carries `defaultLibrary`. A prelude
  macro written in the builtin library (`crash!`) is not `defaultLibrary`:
  the raw lex cannot tell it from a user macro.
- A subscript through a user `op []` / `op []=` (`IndexWalker::
  visit_subscript_expr`): its `[` is an `overloaded` `operator` token whose
  reference is the form Sema selected, so go-to-definition and hover on it
  land on the read or the place form the use actually calls. SubscriptExpr
  keeps no bracket token; the `[` is taken as the byte after the base, as
  OperatorLowering does.
- `deprecated`: a declaration carrying `@deprecated` on itself or its pattern,
  the links `AttributeCheck::_deprecation` reads; its third link,
  `NameLookup::representative`, is `prot` to the compiler module, so a
  redeclaration that carries the attribute only on its representative is
  missed.
- `mutable`: a `VariableDecl` that is neither `const` / `eval` storage nor a
  const binding (parameters are not marked).
- `unsafe`: a call to an `unsafe fn`, the operator of `unsafe <unary-op>`
  (`unsafe &x`, `unsafe *p`), and the `unsafe` keyword itself (lexical, so
  an unsafe cast's keyword is bold too).
- `panics`: a call to a function declared `panic` (the `FnModifier`, not the
  solved set: reading the solved set needs `panic_set_of_fn`, which takes a
  `std::vector`). Always in the snapshot; the server masks the bit out of
  every token unless `initializationOptions.highlightPanics` is true.
- Rule 2 is applied in the server: an extension or C/C++ callee never
  carries `overloaded`.
- NOT SENT: `unused` (the compiler has no unused-binding fact), `inactive`
  (the tree keeps no record of what an `eval if` removed), `moved` (MoveCheck
  does not expose a per-use fact). The clients have no rule for them yet.

Clients (kairo-lsp): VS Code draws underline, italic, bold, strikethrough
and the fixed colours of the `&` rows and of `macro` (an explicit
`macro:kairo` rule, since many themes colour a macro as a function); it
cannot dim, shade relative to a theme, or dot an underline, so `mutable` and
`panics` draw nothing there. Its `&` selectors rely on VS Code preferring
the rule that names more modifiers (`operator.pointer.unsafe.readonly` over
`operator.pointer.unsafe` over `operator.pointer`). Neovim draws `panics`
dotted (`underdotted`), draws `macro` in the same amber, and colours the `&` from
an `LspTokenUpdate` handler (the per-modifier `@lsp.typemod` groups cannot
express a combination). Zed takes the first matching rule, so it lists the
`&` rules first, most modifiers first, and `dispatched` before
`overloaded`.

## 6. Hover

BUILT.

A code block, then where the declaration lives, then its documentation.

- A function: its signature. `Self` prints as written, never as the type it
  stands for. A C++ reference parameter reads as the mode Kairo passes it
  with (`T&` is `@inout x: T`, `T&&` is `@move x: T`, `const T&` is
  `const x: T`), and a reference return as a Kairo definition spells it:
  `-> ffi::ref<T>`, `-> ffi::ref<const T>`, `-> ffi::mref<T>`, for
  an imported declaration and a Kairo override or definition alike.
- A variable, field or parameter: its declaration with its type, inferred or
  written.
- **The head as written**, on the hovered
  declaration and on every member line of a type's body: its attributes in
  source order, spelled from the source text (`@copy`, `@packed`,
  `@align(8)`, `@deprecated("...")`; every one the parser kept, including
  those it also turns into a field), then its visibility keyword (`pub`,
  `priv`, `prot`; a member of a `pub { }` group shows `pub`). A function
  adds its modifiers, which the tree keeps as bits whatever side of `fn`
  they were written on, so they print in one place: `static` / `virtual` /
  `override`, `final`, `inline`, `eval`, `const` before `fn`; `unsafe`,
  `async`, `volatile` and the `panic` specifier (its source text, set
  included) after the parameters; `= default` / `= delete` / `= virtual`
  last. A parameter shows its attributes and an `@inout` / `@move` the
  source wrote, never the one ClassLifecycle gives a transfer
  constructor's `other`. A field or variable shows its storage as spelled
  (`var`, `const`, `static`, `static const`, `thread`, `eval`, `mutable
  var`). Nothing of the kind for a declaration imported from C++ or made by
  the compiler: neither wrote a head. Not shown: a type's generic
  parameters, its `derives` / `impl` lists, a `where` / `requires` clause,
  default values. Completion details, outline details and the Bases.k
  signature comparisons keep the bare declaration (`signature_` without
  `full`).
- **A type shows its body.** An interface lists every requirement, the ones
  it inherits from the interfaces it derives marked `// inherited`. A class,
  struct or union lists its fields and methods, then the methods `extend`
  blocks add anywhere in the build, marked `// extend`.
- **An enum shows its variants**: its underlying
  type (`derives u8`, or `derives u32  // default` for a plain enum
  without one, enums-plain), then every variant, a plain one with its value
  (`Mid = 2`, implicit values included), an ADT one with its payload
  (`Rect { w: f64, h: f64 }`). A variant shows `(variant) Enum::Name = N` or
  its payload. A union lists its members (as a struct does).
- **Size and alignment**: `size N bytes, align M` under the code block, from the compiler's
  own layout query, `EnumLayoutQuery::size_of` -- the one declaration-scope
  `eval if` folds `sizeof` with and codegen pins an ADT instance's
  predicted size to -- in its foreign mode (`EnumLayoutQuery::foreign`,
  off for the compiler, so no `eval if` and no static_assert changes). It
  answers:
  - a plain enum (its `derives` word, else u32), an ADT enum (tag, prefix
    tag or niche, as EnumLayoutLowering laid it out);
  - a struct or class with no base, no generic parameter and no virtual or
    override method, `@packed` and `@align` (on the record or a member)
    applied, whatever its fields' types;
  - an imported C++ record or union, a filled instance of a C++ template
    (`vector<i32>`, `DenseSet<u64>`): clang's `getASTRecordLayout`, which
    DeclImport kept as the decl's ForeignLayout; an imported C++ enum: its
    integer type; a C++ typedef / alias: its target's;
  - a Kairo generic instance (`Pair<i64>`): its pattern by the rule above,
    each field's type at the instance's arguments (the substitution ADT
    instances use, `field_type_at`), refused for an attribute on the
    pattern or a field, a base, a virtual method, or a field type built
    from a parameter other than a pointer (Sema never fills a Kairo
    instance: C++ instantiates the emitted template);
  - a Kairo class with a base (Kairo or C++, `derives virtual` too) or a
    virtual / override / `= virtual` method, a Kairo instance whose
    pattern carries a layout attribute, a `@packed` record with a field of
    record type, and a Kairo union as a field: clang's layout of a
    **layout twin** of the class the compiler emits
    (`EnumLayoutQuery::_twin_record`, built with TypeExport's
    `twin_*`). The emitted class's layout is the Itanium one, and what it
    turns on is clang's POD bit for each base: a non-POD base lends its
    tail padding to the derived class's fields (`class D derives B`, B
    `{i64, u8}`, D `{u8}` is 16 bytes, not 24), and a packed record does
    not pack a non-POD class member. So the twin mirrors every input of
    the layout and of that bit from `InterfaceEmitter::_record_def`: the
    bases in `derives` order with their virtual-ness (all public); a real
    virtual method when the class declares one (clang places the vtable
    pointer and picks the primary base); every non-static field in order
    with its `@align`, a default member initializer exactly where the
    emitter writes one (a folded initializer, else the `{}` of
    `_zero_by_default` and a union's first member), and the access it is
    written at; a user-provided destructor standing for any user-provided
    special member (a constructor or `op finally` with a body, a bodied
    derived `op =`; a defaulted or deleted one keeps a class POD, as clang
    does); `packed` / `aligned` on the record. Field types: a scalar as
    itself, any pointer as `void *`, a Kairo record as its own twin, an ADT
    or `T?` as a non-POD blob of the query's size (both are emitted with
    constructors), a C++ type as that set's own decl, completed, never a
    new template-id. The twin is never the TypeExport stand-in, is in no
    scope, is never registered or found by name, and is built per query
    (an edit of the base reaches the derived hover), under the set's
    `sema_lock()` and with its diagnostics suppressed. The set is the
    asking TU's, else the record's TU's, else the nearest one through the
    imports (a file with no `ffi` import reaches the builtins'). Refused
    when a part has no spelling in that set (an unfilled C++ instance, a
    C++ type from a set that does not include it), for a tuple field, a
    field type built from a parameter other than a pointer, and when a
    POD bit is uncertain where it is read (a compiler-made field's access,
    a `Constrained` `op =`, in a base or a packed member). `impl` adds nothing: interfaces, virtual ones included, are
    not compiled into the class today (a `virtual interface` impl measures
    4 bytes for an `i32`); this follows the emitter if that changes.

  A union is the widest member rounded to the strictest alignment, each
  member's size from the query; not for a generic union or one with an
  attribute on it or a member. An instance is shown where a use names it:
  the last segment of a type (`var p: Pair<i64>`, `sizeof HBox<i32>`)
  gets its own hover, the declaration's text plus the instance's line,
  which names it (`size 16 bytes, align 8 (`Pair<i64>`)`); the pattern's
  own hover shows nothing. Not shown, rather than a guess:
  - a generic pattern; an instance named only inside an expression
    (`cxx::std::vector<i32>()`), whose callee row is the template's;
  - a C++ instance clang never completed (named, never used).

  The numbers are the entry's target's: builtin widths and the header
  sets both follow the invocation's TargetOptions, and the line ends ` on
  <triple>` when the entry passed `--target`. An ADT has a layout only
  once EnumLayoutLowering has built it, so the walker leaves the line's
  place in the hover and the worker fills it from
  `SemaObserver::on_lowered`, after the TU's lowerings and mono
  (`IndexWalker::fill_layouts_`); a TU whose Sema stopped before lowering
  (an unresolved name, a type mismatch such as SC028E) gets no ADT size,
  and an enum of a TU still waiting to lower (its import cycle's later
  member) gets none. Checked against compiled `sizeof` / `alignof` by
  `smoke.py` (`hovers`, `foreign_hovers` with its own header,
  `base_hovers` for bases, virtuals and POD flips;
  `KALS_SMOKE_KAIRO=<kairo>` recompiles the programs instead of the
  recorded numbers).
- Documentation is the `///` block directly above the name, read from the
  source text (the tree does not carry doc comments reliably). A
  license banner is not documentation.

- **A macro invocation** shows what it expands to (`macros`, section 3):
  the heading **Expands to** and the text in a `kairo` code block.

## 7. Inlay hints

BUILT.

| Hint | Where | Kind |
|---|---|---|
| `: T` | after a declaration whose type was inferred | type |
| `name:` | before a call argument; not when the argument is already named or is a variable of that name | parameter |
| the inherited requirements, on one line | inside the braces of an interface that derives others | none |

An inlay hint cannot span lines and editors truncate long ones, so the
interface hint is a glance; the full list is the hover.

## 8. Completion

BUILT. Answered from what the server holds (the index path) wherever it can be; from the compiler otherwise (the marker
path, below).

### What is asked for: the site

`site_at` (`Analyzer/CompletionSite.k`) reads the BUFFER'S TEXT at the cursor:
bytes and the classes `TextScan::classify` gives them (code, comment,
string). No token stream and no tree: the syntax pass's tokens arrive
after the keystroke a completion follows, and the buffer as a rule does not
parse while it is typed. The cursor may be anywhere in or after a name: the
name's two halves are found around it, so a request after a deletion is the
same request as one after a keystroke.

| Site | When | Answer |
|---|---|---|
| none | in a comment; in a string (but for an f-string's `{...}`); in a number; where a name is being DECLARED (after `fn`, `class`, `struct`, `enum`, `union`, `interface`, `module`, `macro`, `type`, `var`, `for`, `catch`, `test`) | an empty list |
| header | inside the string of `ffi "c" import "` / `ffi "c++" import "` | files and directories of the include directories |
| attribute | right after `@` | the compiler's attributes |
| import | in a Kairo `import` statement | module paths and a module's names, from the filesystem |
| member | after `.`, `->`, `::` (not `..`; not `->` in a function's header, which is a return type; not after a number) | the receiver's members |
| name | anywhere else | locals, the enclosing type, the file, its imports, the builtin library, macros, keywords |

A name site also says where it stands (`KC_*`), which decides the keywords
and, in a type position, the names:

| Position | When | Keywords | Names |
|---|---|---|---|
| statement | first on its line in a function's body | statement, declaration and expression words | all |
| expression | elsewhere in a body | expression words | all |
| type | after `->` in a function's header, after `as` `derives` `impl` `extend` `is`, after the `:` of a `var` / `const` / `eval` or of a parameter | primitive type names, `Self`, `const`, `unsafe` | types, modules, type parameters |
| type or expression | after any other `:` (a named field's value, a map's) | both | all |
| declaration | first on its line at file level or in a type's body | declaration words | all |
| parameter | in a function's parameter list before the `:` | `self`, `const` | none |

When the position is not one of these the word is offered: a keyword's row
(`word_context`, `Server/CompletionWords.k`) lists where it CAN stand, and
a word with no row stands everywhere.

### What the server holds

**Declaration tables** (`Index/Tables.k`, `Server/DeclTables.k`): one per
Kairo file of the graph, the library's files too (a file outside the
indexed root is walked for its table alone, `IndexWalker::run_table`).
A table is the file's own declarations, a parent before its members:

| Member | Content |
|---|---|
| `path`, `mod`, `builtin` | the file; its module directory (`tu_module_dir`, "" for none); whether it is of the builtin library |
| `decls` | `[name, kind, parent, off, line, char, vis, flags, detail, tfile, toff, efile, eoff]` per declaration (`DC_*`, Snapshot.k): the LSP CompletionItemKind; the row it is declared in (-1: the file); the byte offset and LSP position of its name; its visibility with the default applied (`VIS_*`); `DF_STATIC` / `DF_METHOD` / `DF_SCOPE` (a type, a module) / `DF_EXT` (an `extend` block: no name, its members are the target's) / `DF_MACRO` / `DF_ALIAS` (declared in another file and bound here; with `toff` -1 the other FILE, as a module); the signature as hover prints it; and the record its TYPE is (a variable's, a field's, what a function returns; through pointers and `?`), as an index into `files` and the name's offset there. For a `DF_EXT` row that is the record it extends. `efile`/`eoff` name, the same way, the record a SUBSCRIPT of the value is: the element of a `[T]`, `[T; N]`, `[T;]`, the value of a `{K: V}` (`Refs.k`, `elem_type_`); on a type's row the record its `op []` overloads agree on; -1 for anything else |
| `bases` | `[row, file, off, vis]` per `derives` edge of a class: the base, and the edge's visibility |
| `files` | the paths `tfile` and a base's `file` index |

Rows name each other by file and BYTE OFFSET of the declared name: no line
map of another file is built to write a table. What a scope row says of a
declaration (its name, kind, place, a C declaration's signature) is the
same for every file that imports it, and a core file is imported by
hundreds: the walks of one check share it (`ScopeFacts`, Snapshot.k;
emptied before each check and re-check, since a replaced tree's addresses
are given out again). The members of a type are
listed by one function for the table and for the marker path's items
(`own_members_`, `tu_decls_` in `Index/CompletionItems.k`), so the two lists
cannot differ in what a type declares.

**Scope rows** (`scope`, `sfiles`, `sees` of a file's block, section 3):
what depends on WHO asks. `scope` is what a bare name reaches through the
file's imports, read from the import overlay (the table name lookup itself
reads), as `[name, kind, sort, file, off, detail?]`: `file`/`off` name the
declaration's table row; `off` -1 means the name is the FILE, a module;
`detail` is written only for a declaration no table has (a C or C++ one).
`sees` is the files whose `extend` blocks the file sees
(`SemaContext::sees_extension_file`).

**How the tables travel.** A run's snapshot carries every table
(`tables`, `tablesAll: true`). The live worker keeps each file's table with
the step that walked it and a snapshot carries the ones walked after the
step the server says it has (`have` in the request, `tablesSeq` in the
snapshot): all of them on a first answer, the edited file's and its
re-checked importers' after an edit. A snapshot the server drops is made
up for by the next, whose request states what was installed; a worker that
is restarted is asked for all. The server keeps the tables per entry,
decoded into columns (`Entry::tb`), whatever becomes of the snapshot's rows:
a table is of a file that was checked, also when the index is not replaced
(section 9). A whole set of tables (`tablesAll`) replaces the tables of
the files it has one for and drops those of files that left the graph
(`deps`). A file of the graph it has none for keeps the table of its last
check: a file left `unchecked` (a syntax error in it or in an import), one
whose check stopped before Sema (an import that does not resolve yet),
every file when the run made no table at all. It would otherwise lose its
own names and macros until it is checked again.

### A name

In the walker's order (`sortText`'s first digit), one item per name, the
first found:

0. **Locals and parameters in scope.** The enclosing function is found in
   the text (`blocks_before`: every `{` before the cursor with what its
   header declares). Its declarations come from the index for the lines the
   buffer still has as the index read them (`LineShift`, section 9: the
   `refs` rows that are declarations of a variable, a parameter, `self` or
   a type parameter, with the type each row carries), and from the text for
   the lines typed since: `var` / `const` / `eval` declarations, `for x
   in`, `catch e`, and the header's parameters when the header is among
   those lines, a closure's parameters with them (`lex_decls`,
   `lex_params`). Such a local's item says its type when the text says it
   plainly: as written (`var x: T`), a construction's (`T(...)`,
   `T<U>(...)`, `T { }`, the head a class or struct of the tables) or a
   literal's at its default type (an integer that fits `i32`, a float
   `f64`, a suffix's type, `string`, `bool`, `char`; the whole initialiser
   one literal), and nothing for a call or any other expression.
   A declaration is in scope when the block it is declared
   in, or the block its header opens (a parameter, a `for` variable, an
   a `case` binding), is still open at the cursor (one test for both
   paths, `CompletionSite::declared_in_scope`). Braces that
   are a value's (`var p = Point { x: 1 }`) open no scope for what stands
   before them; a closure's body (`var f = fn (a: T) {`) is a block from
   its `fn`. The type parameters of the enclosing types' headers are
   locals too. A `case` pattern's bindings typed since are read from the
   text too: they are written `var x` / `const x` (`case .Found(var k, var
   v)`, `case var n`), which the scan reads wherever they stand. (Kairo
   has no `if var`: a nullable is narrowed by `if x?`.)
1. **The members of the types the cursor is inside** (a class's body, not
   an `extend` block: as the marker path).
2. **The file's own declarations**: its table's top level and what its
   `module` blocks hold; and the names the text declares at its top level
   that the table lacks, when the buffer is not the indexed text.
3. **What the file imports** and 4. **the builtin library**: the scope
   rows, each with its declaration's signature.
7. **Macros**: the file's own, the `pub` ones of the files it imports
   directly and of the builtin library (not those of a file a `pub import`
   re-exports: the preprocessor does not expand them either, R013E),
   as `name!` with the invocation as
   detail and, for a client that takes snippets, a placeholder per
   parameter. 8. **The compiler's macros and `name!` intrinsics**
   (`LangMacros::known`, `LangIntrinsics::known`), each with its one line.
9. **Keywords**: every word the lexer makes a token kind of
   (`word_token_kinds`, spelled by `token_kind_to_readable_string`), those
   that can stand at the position.

### A member

The receiver is read backwards from the operator as a chain of names, each
possibly called (`receiver_steps`): `a.b().c`. Its head is `self` / `Self`
(the enclosing type; in an `extend` block the type it extends), a local, a
member of the enclosing type, a name of the file or of its imports. A name
that opens a scope (a type, a module, a file) is that scope; any other is
the record its type is: the row's `tfile`/`toff`, a local's `REF_TYPE_*`,
and for a local the index has no type of, its written type (`var x: T`),
the construction that initialises it (`var x = T(...)`, `T { }`), or its
initialiser when that is itself a chain of names and calls (`var x =
make()`, `var y = self.docs.first()`, `&other.field`), read the same way
in the scope the declaration stands in, four initialisers deep at most.
The index has no type for a local typed since it was built, and none for
ANY inferred local of a file that was last checked with an undeclared
name in it (R020E), which a name still being typed is: Sema then infers no
local's type in any function of that file (hover shows `var box`, not
`var box: Vault`; checked on two functions of one file; an
unknown MEMBER, R025E, does not do it). Each further
step is looked up among the members of what is before it.

The list is the receiver's own members, then the members of the `extend`
blocks of it that this file sees (its own, the builtin library's, those of
the files in `sees`, and one written beside the type), then its bases',
each when the cursor may name it:

- `pub`: everywhere. `priv`: in the member's file and in its own class.
  `prot`: also in the files of its module (one `mod`, not none) and in a
  class deriving from the member's class, which reaches an instance member
  only through an object of its own kind. A member of an `extend` block
  answers from the block's file. A base's members reached through a `priv`
  or `prot` edge are the edge's class's. This is `AccessCheck`'s rule
  (`Sema/Resolve/AccessCheck.k`) read off the rows (`may_name_`,
  `edge_ok_`); the marker path asks `AccessCheck::refuses` itself, so the
  oracle below compares the two readings.
- A name with a leading or trailing underscore is not offered from another
  file (as the marker path).

**A primitive's name before `::`** (`usize::`, `f64::`, `i32::`). No table has a row for a primitive: its associated constants
are the compiler's (`usize::MAX`, `f64::EPSILON`, computed by
`AST/PrimitiveLimits.k` and minted by `PrimitiveLimitDesugar`). Both paths
list them from that table (`Index/Primitives.k`: every `PrimLimit` that
`PrimitiveLimits::exists` gives the type, so `i32::` has no `EPSILON`, as a
use of it is R024E), with the type `result_kind` gives (`const DIGITS:
u32`), then the members of the `extend` blocks of the primitive the file
sees (`extend i32 { static fn ... }`; a DF_EXT row whose target is a
primitive spells it in its `detail`, Tables.k; the marker path asks
`MemberLookup::extensions_of_type` for the builtin canonical). The head
must be the whole receiver and the operator `::`. A value of a primitive type (`n.` with `n: i32`) is
not typed from the index: it goes to the compiler as before.

**Subscripts and parentheses.** A step may be
subscripted (`boxes[0].`, `self.rows[i].`, `make()[k].`, `m[k][j].`) and the
receiver may be a parenthesised chain (`(a.b).`, `(boxes[0]).`; the brackets'
subscripts apply to its last step): `receiver_steps` reads both. A
subscripted declaration of a table is its `efile`/`eoff` (one subscript);
a local, whose rows carry its type but not its element's, is typed by its
type as written or as its hover prints it (`decl_type_text`,
`elem_type_text`), looked up in the file. A subscript of a value of a
record is that record's `op []`: a TYPE's row carries in `efile`/`eoff`
the record its `op []` overloads agree on (`t_decl_`; operator rows are
not in the table); `self[i]` is the enclosing type's, as
are a dereferenced chain `(*p).`, which is the record the tables give the
pointer, and a safe access `x?.`, the record they give the `T?`: both look
through `*` and `?`). Not read: a range subscript (`v[a..b]`, a slice), a
pointer's or a `?`'s subscript, overloads of `op []` that differ. Measured with `completion_bench.py` (live, this repository's kals graph, 20 sites): 15 of 20 receivers are answered from the index (p50 24 ms), 5 from the compiler.

A step the text already names is looked up as a TYPING, not as a list to
offer (`CompReq::typing`): a member with a leading or trailing underscore
from another file, or one the cursor may not name, is still the step the
code wrote and the compiler's walk types through it (`self.t_fids_.` in an
`extend IndexWalker` file, `v->type_->`).

**The index does not type** a range subscript, a literal's or a parenthesised expression that is not a chain of names
(`(a as T).`), a C or C++ value or namespace (`llvm::sys::`),
a call whose result is a type parameter, an untyped local initialised by
anything but a construction or a chain of names and calls: the request
then goes to the marker path, as it does when the list comes out empty.
Never an empty answer for a receiver the tables cannot type. On the kals
graph 8 of 140 sampled member sites (a chain of names before the
operator) went that way, and 10 of 200 in a typing session. A function's
name is its result only when it is CALLED, and only when every function of
that name beside it returns the same record: which overload a call picks
is the compiler's to say, so overloads that differ go to the marker path;
a value that is called (a closure) does too.

### Attributes, headers, imports

- **After `@`**: `LangAttrs::known` (the list `AttributeCheck` admits),
  each with how it is written (`LangAttrs::usage`: `@align(N)`) and one
  line on what it does (`LangAttrs::summary`), sent with the item. When
  the declaration that follows is already written (`fn`, `class` /
  `struct` / `union`, `enum`, `var`, `if` / `else`), only the attributes
  that may stand before it (`LangAttrs::targets`). User-defined attributes
  (`macro @name(...)`) are not listed: the language has them, but every use
  is SC116E until they are expanded (attributes.mdx), so an item would
  write code the compiler refuses.
- **In `ffi "c" import "` / `ffi "c++" import "`**: the files and
  directories under the file's own directory and the include directories
  of the entry's compile, which are the `-I` / `-isystem` /
  `-internal-isystem` words among the C or C++ driver words every snapshot
  carries (`c_flags`, `cxx_flags`: what kcc gives a C or C++ source,
  the clangd bridge's flags). Headers by extension, and for C++ the
  extensionless ones (`vector`); a directory inserts its `/`, which asks
  again.
- **In a Kairo import** (`import a::b::`, `import a::{x, `): from the
  filesystem. Path segments are directories and `.k` files
  under the search roots (the file's directory, the entry's directory and
  `-I` roots, and every directory holding a `module.k` beside a library the
  last run read); after a file, the names it declares at top level. On a
  later line than the `import` only inside the brace list that line opens.

### The answer

- The WHOLE set for the position, `isIncomplete: false`: the client filters
  it as the word grows or shrinks and does not ask again. (A set filtered
  by the typed prefix would have to be `isIncomplete: true`, a request per
  keystroke, or be wrong after a deletion.)
- The range an item replaces (the name up to the cursor) is stated once,
  in `itemDefaults.editRange`, for a client that reads it there
  (`completionList.itemDefaults`), else on every item as `textEdit`: an
  editor left to guess uses its own idea of a word, which is wrong inside a
  string and after `::`. A macro's name typed before an invocation already
  written (`tw|!(a)`): its item carries its own `textEdit`, over the name
  AND the `!`, with `name!` alone (no snippet), else accepting it would leave
  `twice!!(a)`; not before `!=`.
- `detail` is the signature as hover prints it. Documentation is not in
  the list: an item of a declared name carries `data: [file, line]` and
  `completionItem/resolve` reads the `///` block above that line from the
  file's text (`doc_above`). Builtin attributes and macros carry their one
  line in the list.
- `$/kals/completed`: `how` (`index`, `text` for a Kairo import, `live`,
  `run`), `what` (`name`, `member`, `attribute`, `import`, `header`,
  `none`), `count` (items), `us` (the server's time from the request to the
  answer).
- Trigger characters: `.` `:` `>` (a member), `@` (an attribute), `"` and
  `/` (a header's path, which is in a string, where an editor does not ask
  by itself). A name needs none: every editor asks as a word is typed. Not
  a space after `import`: it would ask after every word. A request a
  trigger character sent (`context.triggerCharacter`) is answered only
  where the character means its trigger: `/` is also a division, `"` any
  string's quote, `>` a comparison, `:` a type's colon, and a list after
  each of those would be noise. Asked for by hand at the same place, the
  list is given.

### The marker path (the compiler's answer)

For a receiver the index does not type, an entry with no tables yet (its
first check has not landed), a file with no rows, and for everything when
the index path is off (`initializationOptions.indexCompletion: false`, or
`KALS_INDEX_COMPLETION=0`): the server copies the buffer, replaces the
identifier under the cursor with a marker identifier
(`completion_marker()`), and has the copy checked. The marker parses as a
name wherever a name can go, Sema leaves that one node unresolved, and the
walk finds it by spelling: after `.`, `->` or `::` it lists the members of
what is on the left (a value's type, a type, a module); on a bare name it
lists locals, the enclosing type, the file, and what the file imports, in
that order. The two paths agree: a member
the use site may not name is not offered (`AccessCheck::refuses`), the
methods of the `extend` blocks the file sees are (`MemberLookup`), a file's
top-level `const` / `var` is among its names, and the locals are the
enclosing function's whose block is still open at the marker, by the index
path's own test on the text (`CompletionSite::declared_in_scope`). A
declaration of this file outside every function (a field after a method) ends
the walk's function (`visit_decl` resets `cur_fn_`), and the enclosing
class's members are read from the field's context (`cur_dc_`).

With a live index worker (section 10) the marked copy is sent to the
entry's worker as a request of asides alone (`only`,
`Server::live_complete_` in `LiveIndex.k`): the worker's COPY re-checks that
one file with the marker in it and writes the file's rows, `items` among
them, and `finish_complete` reads them as it reads a run's. A process per
request remains for: an entry without a live worker (ad hoc, past the cap,
the option off, no pipes), an entry whose first check has not landed, a
worker that does not answer within `LIVE_ASK_TIMEOUT_MS` or dies, a copy
that could not be made or failed. One completion worker at a time: a
request that arrives while one runs replaces any request already waiting,
which is answered empty. An index answer waits behind neither.

### Checked

`Analyzer/Dev/completion_oracle.py` starts two servers on a workspace, one
with the index path off, and compares the declared names each offers at
sampled member and name sites, on the text as indexed and on a text with a
line typed above the site (the index stale, the buffer not parsing). Member sites whose
receiver is subscripted or parenthesised are compared too (kind `indexed`,
including `self[i].`, `(*p).`, `x?.`). A name
site in a TYPE position (read off the text by the server's rule: after the
`:` of a `var` / `const` / `eval`, after `as` `is` `derives` `impl`
`extend`, after a parameter's `:` in a header with no body yet) is
compared with the TYPES of the oracle's list: the index path offers only
types there by design and the compiler's walk every name, so the two lists differ there by design. The sites the index path left to the compiler are
listed with their receivers.
`Analyzer/Dev/completion_bench.py` times a typing session by kind
(section 11).

On the kals graph (446 files, release kals) the oracle compared member,
indexed and name sites of 8 to 14 files, 10 to 12 sites of each kind and
variant, fresh and stale: no label differs. The index path left 14 of 114
`indexed` sites and 2 of 144 `member` sites to the compiler, and no `name`
site. Every such fallback is a C++ value (`cxx::std::vector`, `SmallVector`
elements: `c->derives_list[i].`, `e->targets[k].`, `all[i].`, `refs.`) or a
generic's `op []` (`FrozenList<T>`: `im->path_segments[0].`,
`f->op_token[0].`, `f->params[pi]->`). A name site in a type position is
compared by types and agrees.

The script sets nothing aside: a local of a block that closed before the site
is offered by neither path, which use the same block-scope test. The sites
the oracle does not answer are a stale line inserted inside a statement that
goes on over several lines (the marked copy does not parse) and sites the
script takes for names that are not (the `f` of an `f"..."`, the letter of a
`'A'`): the index path offers names at the first and nothing at the second.

## 9. Freshness: what is answered when

BUILT.

The server holds, per entry, the last run's output (its diagnostics) and the
last run's output that indexed files (`idx`), with the revision each was
computed at. A buffer records the revision of its last change.

| Situation | Answer |
|---|---|
| The entry's index is at least as new as the buffer | from the index |
| The entry has never produced an index and a run is due or running | wait for it (up to two minutes), never an empty answer |
| A run for the current text is due or running, and the entry's runs are fast | wait for it (the request is "parked") |
| A run is due or running and the entry's runs take over about a second | do not wait: fall through to the next row |
| The buffer does not parse, its syntax pass saw the current text, and the entry has no index of that text | semantic tokens: the index's on the lines the edits did not touch, the syntax pass's lexical ones on the others (section 5; all lexical when the text the index read is not known); everything else as in the next rows |
| The index is OLDER than the buffer (a run has not landed, or the text does not parse and the last good index was kept), at a position on a line the edits did not touch | hover, definition, declaration, typeDefinition, implementation, references and documentHighlight from that index, mapped between the two texts (below) |
| The index is OLDER than the buffer, the text it read is known, and no index of this text is about to land (the buffer does not parse, or the entry has no run due): what the editor DRAWS per line | inlay hints, code lenses and semantic tokens: every row on a line the edits did not touch, at that line's place in the buffer; the rows of the changed lines are not sent (tokens: the syntax pass's lexical ones there, so a token request waits, `ContentModified`, until that pass has seen the text). The editor is asked to refresh when an index of the text lands |
| The index is OLDER than the buffer, anywhere else | `ContentModified` (-32801) for document symbols and links, for references and highlights, and for hints, lenses and tokens when the text the index read is not known; `null` for the rest of what is asked by hand at a position (hover, definition, rename, the hierarchy prepares); fix-its from the current diagnostics; no macro actions |

The first four rows are `Server::answerability` (`Features.k`), one
function returning `Fresh`, `StaleSlow`, `StaleWaitable`, `FirstPending` or
`NoEntry`; `feature()` finds or starts the entry (`ensure_entry`) before it
asks. A Kairo file no entry holds YET is `FirstPending`, not `NoEntry`:
`ensure_entry` has no entry for it only while a
candidate's first run is due or going (the run that says whether that
entry imports the file; failing every candidate, the file's own entry is
made), so it waits as for a first index. As `NoEntry` it would be answered from
no snapshot after `PARK_LIMIT_MS` (3 s): a null hover in the middle of the
run that would answer it (`first_pending` in the smoke test, every
run held back 4 s).

`ContentModified` is the point of the last row. An index older than the
buffer has positions that are off by the edits since; sending them makes the
editor draw hints, lenses and colours in the wrong places until the next
answer. Told `ContentModified`, the editor keeps what it has, which it has
been moving with the text itself, and asks again. **Nothing the editor draws
is ever sent from an index older than the buffer** at a position that index
cannot place on the current text: highlights, inlay hints, code lenses and
semantic tokens are sent only through the line mapping below, a row at a
time, and a row on a line the mapping does not keep is not sent.

**One rule for what is drawn.** A stale index does not by itself make hints,
lenses and tokens `ContentModified`: with one broken line the names of the
whole file keep their semantic colours. Each (`Features.k`,
`Server::merged_tokens` in `Tokens.k`, `code_lens`) is answered through
`LineShift`: the index's rows for the lines both texts
start with and the lines both end with, the second group moved by the
difference in length; for tokens the changed middle is filled with the
syntax pass's lexical tokens of the current text, in position order
(prefix, middle, suffix). Not while a run of a text that parses is on its
way: the editor keeps what it has for those milliseconds
(`ContentModified`), since a mapped answer would turn the names of the line
being typed lexical on every keystroke. A delta is still computed against the array last
SENT for the document (`tok_data`), whatever it was built from, so a
`resultId` names exactly that array.

**Answering on the lines an edit did not touch.** Without it one
syntax error blanks every hover and jump in the file for as long as it
stays. Each buffer keeps the text its file's last good index read
(`Document::idx_text`): the overlay a run was handed, captured when the
run starts (the buffer has usually moved on by the time it lands), or the
disk text of a buffer opened unchanged. It is used only for the index of
that entry and revision. A request then compares the two texts by lines:
the lines both start with map to themselves, the lines both end with map
with the difference in length (never overlapping the first), and nothing
in the changed middle maps. A request on a mapped line is answered from
the old index at the mapped position; every position of the answer in the
same file is moved back, and one in the changed middle is left out (a
definition there is `null`); positions in other files are as their index
has them. A macro hover needs the whole invocation on one side of the
middle. Rename and prepareRename still refuse: a rename's edits would miss
the uses in the changed middle. The hierarchy prepares refuse too (the item
is asked about again later, against whatever text is current then).
Limits: the answer is what the old text meant, so a type or signature
changed by the edit itself shows as it was; and an edit that opens a string
or block comment leaves the identical lines below it answering although
they are no longer code.

**A graph with syntax errors is still indexed** (a file
broken when it is opened, or after a restart, has no last good index to map
from). The worker runs the compile with `--check-past-syntax-errors`
(`Driver/CompilerRecovery.k`): the parse's errors do not fail the action
before Sema, provided every one of them is some file's own parse error (one
the PP or the dependency scan reported -- an unresolved import, a lexing
error -- keeps the old behaviour, and so does a broken file under the
builtin root or a `--prelude` / `--force-include`). The action still fails
after Sema, and nothing after Sema runs. Per broken file:

- **Errors all inside function bodies that kept them** (the parser recorded
  the body: it ended at the `}` the text pairs with its `{`, so everything
  outside it parsed as it would have; Parsing.md, error recovery): the file
  is checked with those bodies dropped (`FunctionDecl::body_recovered`),
  each such function its signature alone. Its healthy declarations, above
  and below the error, get every row; the dropped body gets none (hover,
  definition and references inside it answer nothing; its tokens are the
  lexical pass's). Uses of the function elsewhere resolve to it and its
  signature is shown. Not for an out-of-line member definition, an
  `eval`/`const`, `inline` or `where` function: those fall back as below.
  The snapshot names the file in `partial`.
- **Anything else** (an error outside a body, or a body whose recovery ran
  past or stopped short of its own `}`, as an unclosed `(` does: `foo(1,`
  before the `}` closes the body on that `}`, but the `}` pairs with nothing
  while the `(` is open; `var x = 1 +` before the `}` is not such a
  case, since recovery leaves the `}` for the body): the file is not checked, nor
  is any file that imports it, directly or through others; the snapshot
  names each in `unchecked`. Every other file (its imports, its siblings) is
  checked and indexed as usual.

**Which index answers.** An entry keeps one index. A run's index replaces
it unless it would erase complete rows: when the kept index has COMPLETE
rows (not `partial`, not `unchecked`) for a file the new run has as
`partial` or `unchecked`, the kept one stays, as it does for a run that
indexed nothing, until the file parses again. So a file that was healthy
and is broken answers from its last complete index through the
line mapping above, including on the untouched lines of the broken body;
a file that has been broken since it was opened answers from the partial
index of its current text, which is positionally exact, and answers nothing
inside the dropped bodies. What the kept index does not cover is the cost:
while it is kept, a new healthy declaration in the broken file, and edits to
other files of the entry, are not indexed. Semantic tokens of a broken
buffer come from its syntax pass unless the current index has rows for that
file.

Rename and prepareRename refuse while any entry's index lists a `partial`
or `unchecked` file: the uses there are unknown, and a rename would miss
them silently. References and document highlights still answer, without
the uses in those files or bodies (the same incompleteness the line mapping
above already accepts for the changed middle).

Diagnostics: the run's are exactly the normal mode's, plus what Sema
reports about healthy declarations it now reaches (a type error in a
healthy function of the broken file, or in a file beside it). Nothing is
reported inside a dropped body or because of one: `Scripts/syntax_recovery_diff.py`
type-checks every file of `Tests/` that has a syntax error with the mode off
and on and classifies each extra diagnostic; the bar is no cascade.
Not done: checking INSIDE a broken body (statement-level poisoning) needs
recovery that keeps every name a broken statement declared (`_parse_var`
drops a recovery initializer; a destructuring declaration whose value fails
becomes one error statement, `DestructuringDeclStmt::create_error`, and its
names vanish) and a poisoned type every pass treats as already diagnosed.

**Diagnostics are the newest result per buffer.** Each open buffer gets a
syntax-only pass (section 10) and its entry gets a run. For a buffer whose
syntax pass saw a later text than the entry's last run: the pass's errors,
plus that run's diagnostics for the buffer that are not syntax errors (those
are at old positions, or fixed). Otherwise: the run's. So a syntax pass of
revision N is never overwritten by a run of a revision before N, a clean
syntax pass does not hide the run's semantic diagnostics, and the
diagnostics of every OTHER file of the entry are the run's until the next
run. The syntax pass's fix-its are not offered (the run's are).

**A syntax pass lands only for the text the buffer still holds**,
on both paths, the persistent worker and the process-per-pass fallback
(`SyntaxState::land`): an answer for a buffer changed after the pass was
started has the old text's positions and is dropped, and the pass of the
newer text follows. An answer older than one that has landed is dropped
too.

`workspace/semanticTokens/refresh` is sent only when a run changed results
for a buffer that was not itself edited (an open importer), or when a stale
answer went out. Sent after every run it makes an editor discard what it
just drew.

## 10. Scheduling

BUILT.

- **The syntax pass has no debounce.** Each change is sent to the
  persistent syntax worker (section 11; `Server/SyntaxWorker.k`) on the
  turn it arrives, one request in flight (two writes in flight could fill
  both pipes and deadlock); a buffer typed into meanwhile is sent when the
  answer lands, so the newest revision supersedes every one typed during
  the pass. The answer pipe is in the loop's poll with stdin
  (`kals_poll2`), so an answer wakes the loop at once. An answer for a
  buffer changed after it was sent is stale and dropped (its positions are
  the old text's); the newer text's pass starts on that turn. That is the
  publish coalescing: typing faster than one pass publishes nothing until a
  pause of one pass's time. A worker that
  dies (EOF or a failed write) or does not answer within
  `SYNTAX_SERVER_TIMEOUT_MS` is restarted at once and that pass runs as a
  process; after `SYNTAX_SERVER_MAX_RESTARTS` the session uses the process
  path only (logged both times, `window/logMessage`). It is recycled
  between requests after `SYNTAX_SERVER_MAX_PASSES` (400) or above
  `SYNTAX_SERVER_MAX_RSS_MB` (400; Linux `/proc`, elsewhere the count
  alone).
- **Debounce, per bucket**, in milliseconds since the last change to any
  buffer: on the FALLBACK path only (no pipe shim: Windows today,
  `TODO(WINDOWS)` in `kals_io.h`; or a worker that keeps dying), the
  syntax-only pass of each edited buffer after
  `initializationOptions.syntaxDebounceMs` (default 100); the run after
  `debounceMs` (default 150). The loop's wait is cut to the nearer
  deadline that can start (an entry `can_start` refuses is not one), so a
  pass starts on time and the loop never spins. On the fallback path, one
  syntax pass per buffer at a time and two at once in all (each is a
  compiler process); a change during one leaves the buffer due for another,
  and the pass in flight is then dropped when it lands (section 9), as on
  the persistent path. How long a parked request waits (section 9) is wall
  time, not loop turns.
- **A worker that cannot be started** leaves its work due: an index
  run's entry stays due, a buffer's syntax pass stays due, a bridge row's
  header job stays due. Every start goes through `Server::launch_job`, and
  the owner's "started" transition is made only when the process started.
  The next launch of any worker is tried `LAUNCH_RETRY_MS` (250) later,
  doubling per refusal in a row up to `LAUNCH_RETRY_MAX_MS` (8000), and
  the first refusal of a run of them is logged once. After
  `LAUNCH_GIVE_UP` (6) refusals in a row an entry's run is taken as not
  coming: the entry counts as run with no snapshot, so a request waiting
  for its first index is answered from nothing, until the next change. A
  completion whose worker cannot start is answered with no items.
  `KALS_DEBUG_LAUNCH_FAIL=kind=n,...` (index, syntax, header, complete,
  syntax-server) refuses launches for a test.
- **What starts a run, and what does not.** BUILT. A run is a whole
  compile of the entry's graph, so it starts only when the text the
  compiler would read changed: a `didChange`, a disk change to a file no
  buffer overrides, a buffer closed with unsaved edits, a buffer opened
  with text that differs from the disk or that the last run did not index
  (on a wide graph only open buffers are indexed, so opening a new file
  there still costs a run). `didSave` of an open buffer starts none (the
  buffer is the worker's overlay already), nor does opening or closing a
  buffer whose text is what the last run read from the disk
  (`Server::unchanged_on_disk_`).
- **A stale slow run is killed.** BUILT. A change to a file of an entry
  whose run is in flight kills that run when the entry is known to be slow
  (`SLOW_RUN_MS`) and has run before; its result is dropped without a
  warning and the entry runs again after the debounce. A slow entry's
  debounce is `SLOW_ENTRY_DEBOUNCE_MS` (400), or `debounceMs` when that is
  larger, so a run is not started and killed between two words. Fast
  entries and first runs are never killed. Measured on the kals graph
  (420 files, release): fresh results 10.3 s after an edit made 3 s into a
  run (17.5 s without the kill).
- **Reuse between runs is the live worker's.** A process per run re-checks
  every file of the graph (10.1 s release, 36.5 s debug, on the kals graph);
  the live worker below re-checks the edited file and what imports it
  (IncrementalSema.md phase 5).
- **Workers.** One completion worker, and up to two index workers
  (`initializationOptions.maxWorkers`) when both graphs are small; a graph
  over 96 files, or one not measured yet, runs alone. Each worker is the
  multi-threaded compiler.
- **Lazy entries.** A project entry is analysed when a buffer needs it
  (section 2).
- **Slow entries.** When an entry's run takes over about a second, requests
  are no longer parked on it (section 9).

- **Session lifecycle** (LSP 3.17, "Lifecycle Messages";
  `Server::Session`). Before the `initialize` request a request is
  answered `ServerNotInitialized` (-32002) and a notification is dropped,
  except `exit`. A second `initialize` is `InvalidRequest` (-32600).
  Requests are served once `initialize` is answered; the server's own
  notifications (log lines) wait for `initialized`. `shutdown` ends all
  work before it answers: parked requests and a waiting completion are
  answered `RequestCancelled`, every worker process is killed and reaped
  (a completion in flight answered `RequestCancelled`, every progress token
  ended), the syntax and live workers stopped; nothing is started after it.
  A request after `shutdown` is `InvalidRequest`, a notification dropped.
  `exit` ends the process, with 0 after `shutdown` and 1 without; the same
  stop runs at the loop's end (an `exit` with no `shutdown`, or the editor
  gone) before the scratch directory is removed.

PLANNED, with the budget of section 11: cancellation of a worker whose
input is already stale (a process cannot be recalled today; with a persistent worker
it is a flag checked between files).


### The live index worker (`liveCheck`)

BUILT. On by default; a buffer that does not parse stays on the live path.
Off with
`initializationOptions.liveCheck: false`; the server's environment decides
for a whole session whatever the client sends: `KALS_LIVE_CHECK=0` is off,
`KALS_LIVE_CHECK=1` is on (a test suite run in one mode). Off, nothing below
runs and every analysis is a process per run. Every fallback to a process
per run below stands (an entry no project lists, no pipes on the platform,
a worker that dies, a refused command line).
`Analyzer/Server/LiveIndex.k` (server), `Analyzer/Index/LiveWorker.k`
(worker), `Compiler/Tooling/LiveCheck.k` (the compiler's API).

**The process.** `kals --worker --index-server --cwd <dir> --root <project> --
<args> <entry>`, started like the syntax worker (`kals_child_spawn`), one per
entry, kept in `Server::lives`. It runs `LiveCheck` with `in_place` and
`two_tier` and the per-run worker's `IndexObserver` in `keep` mode: each
walked file's rows are kept by path, each owner's diagnostics as rendered
rows, and a step replaces those of the files it re-checked. A diagnostic row
is never rendered twice: a kept row's positions may be in text another
file's edit has replaced.

**The wire.** LSP-framed JSON on the worker's stdin and stdout, small on
purpose: buffers and snapshots are FILES, so neither side can fill a pipe
the other is writing to, and the server may send while the worker answers.

```
in:  { "id", "out": <path>, "open": [ { "path", "file" } ], "changed": [path], "progress": <path> }
out: { "id", "ok": true, "mode": "full" | "refresh", "why", "rechecked", "pending",
       "touched", "files", "out", "us", "retiredFiles", "retiredMb" }      the first tier
     { "id", "ok": true, "bg": true, ...the same..., "out": <path> | "" }  one per background slice
     { "id", "superseded": true }      { "id", "ok": false, "error" }
```

The member names are `RQ_*` (requests) and `RP_*` (answers) in
`Analyzer/Index/WorkerKeys.k`, shared by `LiveIndex.k` and `LiveWorker.k`
(and the syntax worker's, by `Server/SyntaxWorker.k` and `Index/Worker.k`).

`open` is every buffer of the entry as a scratch file; the worker compares
each with the text it holds, so a server that is ahead of it (a run it did as
a process) needs no bookkeeping. `changed` names files changed on DISK with no
buffer open (`Entry::live_changed`, filled by `touch`). Requests that arrive
while one is being answered are joined (newest buffers, changed lists united)
and the older ids answered `superseded`.

**Two tiers.** The answer to a request is the edited files re-checked (each
with the queued files it imports) and a whole snapshot in the per-run
worker's format, in which the files that import them keep the rows and
diagnostics they had; `pending` says how many are queued. The worker then
re-checks the queue `LIVE_SLICE_FILES` (4) at a time, in the order Sema runs
files (an import cycle is one step whatever its size: 24 files is the
largest here), looking at its stdin between slices. `LIVE_PREFER_OPEN`
(on) does the editor's buffers and what they import first, after the queued
files that were first to use a generic instance they name, so the
preference never costs a whole check (IncrementalSema.md, "Preferred
order"). Each slice is one more answer under the
same id (`bg`); a slice that changed nothing a snapshot holds (no open buffer
among its files, no diagnostic row that moved, a wide graph) sends its counts
and no snapshot. A request that arrives during the drain is answered first,
and the id that was draining is answered `superseded`: what it left queued is
the new request's.

**The server.** `live_send` instead of `start_index` for an entry that
`live_takes`; every answer with a snapshot goes through `finish_index` as a
run's output does (the whole-snapshot install path). `$/kals/analysed` gains,
for a live answer only: `mode`, `why`, `rechecked`, `pending`. One
notification per answer, so an edit of a file with importers gives one with
`pending > 0` and more until `pending` is 0; `lsp_client.settle` waits for 0.

**Freshness of a queued file** (`Entry::live_pending > 0`). The entry is
fresh as soon as the first tier is installed: the edited file's answers are
exact. A file whose turn has not come answers from its previous rows, whose
positions in ITS text are exact (it was not edited) and whose statements
about the edited file (a definition's line there, a type) are the old ones;
`owe_refresh` is set, and when a slice re-checks an open buffer (`touched`)
the editor is asked to redraw (`semanticTokens/refresh`, `inlayHint/refresh`).
Its diagnostics stay until its turn. `rename` and `prepareRename` answer null
while anything is queued: their edits come from every file's rows.

**A buffer that does not parse is tried aside.** A process per run for every
half-typed line would be a whole run and "Indexing" at nearly every pause on
a 427-file graph, so `live_send` names the buffer in `aside`, and in `open` gives the
worker the text to KEEP for the file: the one the entry's index read
(`Document::idx_text`, the last that parsed), sent as any buffer is so that
a worker started since holds it too; when no such text is known the worker
has, and keeps, the disk's. The worker, after the request's own step, makes a COPY of itself (`kairo::aside_fork`,
`Compiler/Native/Shims.hh`: fork, copy-on-write). The copy gives the buffer
its text and re-checks it as an edit's first tier does, with
`LiveCheck::past_syntax` (the rule of `--check-past-syntax-errors` for one
file: syntax errors that all sit inside function bodies drop those bodies
and the rest is checked, `partial`; an error anywhere else refuses it,
`unchecked`, with the parser's errors of this text; a refusal made BEFORE
the text was read, from the graph as it stood (the file's kept text has
syntax errors of its own, it declares a specialization, ...), is `none`:
what the copy then holds is the kept text's diagnostics, and nothing was
found out about this one), writes the file's diagnostics and rows to
`asideOut`, and ends. The worker never sees the text, so by construction:

- the checked graph is the last good one: no importer is retracted or
  queued, a draining queue is only paused for the copy's lifetime, and the
  next text that parses is one ordinary re-check from that state;
- the entry's index keeps the last good rows of the file, answered through
  `LineShift` (section 9). The server makes the buffer newer than every
  index installed while it is held back (`Job::held_paths`, `finish_index`),
  which is what "the index is of an older text of this buffer" means;
- the buffer's diagnostics are the copy's (`Document::side_diags`,
  `compose_diags`), which read exactly this text: the parser's errors and,
  when `partial`, what Sema says of every healthy function, at current
  positions. They stand until the buffer changes. A `none` is not a
  result: the syntax pass's errors and the last run's stand;
- a file that is broken where the worker reads it (on the disk, before
  the server ever indexed it) is the worker's WHOLE check's business: it
  runs with `--check-past-syntax-errors`, as a run does, and its snapshot
  names the files it left `unchecked` or `partial` (`LiveState`), so such a
  graph has the rows a run gives it. The first text of the file that
  parses is then a whole check once (`a diagnostic from before Sema`: the
  parser's errors of the kept text have no owner to replace them by);
- `$/kals/analysed` carries `mode: "refresh"`, `rechecked: 0` and `aside`
  (the states, comma-joined); rename is refused while any buffer is held
  back (`any_incomplete_index`).

Every later request repeats the aside for each buffer that still does not
parse, so an edit of another file in between (kept, re-checked in place)
leaves the broken buffer's result current. Where a process cannot be copied
(`aside: "unsupported"`; the live worker itself needs pipes, so today that
is nowhere it runs), or the copy fails or passes `LIVE_ASIDE_TIMEOUT_MS`,
there is still no run: the syntax pass's errors and the last good index
answer. The request's members are `RQ_ASIDE`, `RQ_ASIDE_OUT` and
`RQ_ONLY`, the answer's `RP_ASIDE` (an `ASIDE_*` word) and `RP_ONLY`, and
what the copy writes is keyed by `AS_*` (states `checked`, `partial`,
`unchecked`, `none`), all in `Analyzer/Index/WorkerKeys.k`;
`$/kals/completed` is `M_KALS_COMPLETED` with `K_HOW` (`HOW_*`) and `K_US`
in `Protocol.k`. Proof of the copy's result: `Tests/Sema/Incremental/replay_aside.k`
(IncrementalSema.md, "Aside").

**Fallbacks**, each ending in a correct snapshot:

| When | What happens |
|---|---|
| the entry is one no project lists, or past `LIVE_MAX_CHILDREN` (2) | a process per run, always |
| a changed buffer does not parse (the syntax pass's verdict, waited for up to `LIVE_SYNTAX_WAIT_MS`) | NO run of any kind: the text is tried ASIDE (below); the live worker keeps the last text that parsed and catches up by comparing texts when one parses again |
| a changed buffer parses only as far as the syntax pass can tell (`unsure`: macros of an imported file) | tried ASIDE first (`Document::held_back`): when the copy checks it whole (`checked`), or finds out nothing (`none`, no copy, a copy that failed), the next request KEEPS it, one ordinary re-check; `partial` or `unchecked`, it is held back as a text that does not parse. Sent to the worker without that, such a text is refused by its in-graph parse: a whole check (`a diagnostic from before Sema`) for the text, and another for its fix (`unsure_syntax` in the smoke test). A text that expands well costs the copy's re-check before the kept one |
| `LiveCheck` cannot re-check in place (`mode: "full"`, with `why`) | the whole check inside the worker; the answer is a complete snapshot |
| the worker dies, or a request passes `LIVE_TIMEOUT_MS` | restarted; that revision is a process's (which reports a crash the text causes); after `LIVE_MAX_RESTARTS` the entry is a process per run for the session |
| the command line is refused | the worker is stopped and a process run says why |
| resident size over first-check size x `LIVE_RSS_FACTOR_PCT` + `LIVE_RSS_SLACK_MB` | restarted between requests, its first check started at once in the background while the entry answers from the snapshot it has |
| the same over `LIVE_RSS_IDLE_PCT`, editor quiet for `LIVE_IDLE_RECYCLE_MS` | the same restart, when nobody is typing |
| no pipes on the platform (Windows today) | a process per run |

How often, on this repository's graph: of the scripted and benchmarked edits
(trailing-comment and body edits, a broken and fixed constant)
none took `mode: "full"`; every half-typed line takes the "does not parse"
row, which is one file's re-check in a copy of the worker; the resident limit is reached
after about 35 edits of 13 to 22 file sets or 2 edits of a core file (see
IncrementalSema.md, "Memory").

**The wide-graph rule in live mode.** Above `WIDE_INDEX_LIMIT` files a
snapshot still holds only the open buffers' rows: the server installs a
snapshot whole, and a snapshot of every file per slice would cost more than
the re-check. But the WORKER walks every file under the project root at the
first check and after each re-check, and keeps the rows. So opening a file
later is answered with nothing re-checked (`rechecked: 0`), where a process
per run starts a whole run for it. Walking is about a quarter of a check; a
buffer outside the root that has no rows is re-checked to be walked. What is
not built: installing one file's rows into the server's snapshot without
replacing the document (`index_cache` decodes one `JsonDoc`), which is what
references and rename over a wide graph's unopened files would need.

**Measured** (release kals, workspace = this repository,
`Analyzer/Driver/kals.k`, 426 files, `debounceMs` 0; `python3
Analyzer/Dev/live_bench.py <kals> <workspace> --entry Analyzer/Driver/kals.k
--file <f> ... --edits 3 [--no-live]`): a comment appended to a buffer of
`Analyzer/Tuning.k` (22 importers) has its results in 130 to 170 ms and is
drained in about 0.8 to 1.1 s; one of `Analyzer/Server/TextUtil.k` (a 19-file
import cycle) in 0.7 to 0.8 s; one of `Compiler/Support/ShellQuote.k` in
about 135 to 180 ms; one of `Compiler/Location/SourceManager.k` (258
importers) in 0.2 to 0.3 s and drained in 9 to 18 s (54 answers, most of it
re-checking and walking each file for its rows). An edit of `Tuning.k` sent
during that drain has its results about 630 ms later with 238 files still
queued. The first check takes about 12 s. The same edits with a process per
run are a whole run each, 14 to 25 s.

The worker's resident size is about 4.4 GB after the first edit; each of
the first edits of a file adds 20 to 40 MB, then it stays flat (50 edits of
`Tuning.k` one after another: 0.5 MB an edit, no restart; 200 edits from a
fresh worker: 1.4 MB an edit). An edit of `SourceManager.k` adds 0.27 to
0.32 GB, of which 0.15 to 0.2 GB is held: the C++ template instances over
its records, filled again. The limit (7.5 GB for this graph) is a dozen
core edits or hundreds of leaf edits away. `LIVE_RSS_IDLE_PCT` (130 %) is
passed after one or two core edits: an idle restart then, which the freed
trees do not make necessary.

## 11. Latency budget

TARGET. The numbers the work is held to, on a codebase the size of
`Compiler/` (several hundred files), measured from the event to the answer.

| Feature | p50 | p95 | Notes |
|---|---|---|---|
| Semantic tokens after an edit settles | < 50 ms | < 150 ms | never flicker |
| Syntax diagnostics | < 100 ms | < 200 ms | from the keystroke; no debounce (see below) |
| Sema diagnostics | < 150 ms | < 300 ms | past 400 ms they are not trusted |
| Completion | < 80 ms | 150 ms | hard cap 150 ms: show what there is, then stream more. From the index (section 8): under 50 ms, measured below |
| Signature help | < 50 ms | < 100 ms | |
| Hover | < 50 ms | < 150 ms | |
| Go to definition | < 200 ms | < 500 ms | |
| References | | 500 ms cap | user initiated |

**Completion, measured.** A release kals on the kals graph (446 files),
`Analyzer/Dev/completion_bench.py`: a typing session per kind, every request
after a `didChange` of one keystroke or deletion on a line that as a rule does
not parse, timed as the server's own time from the request to the answer
(`us` of `$/kals/completed`). Every kind answered from the index or the text
is under 50 ms at its slowest request, also on a machine at load average 45:
at a lighter load the p50 is 2.6 ms for names, 1.6 ms for members from the
index, 0.1 ms for attributes, 0.5 ms for imports and 1.2 ms for headers. The
rows the compiler answers are not (a member of a C++ value such as
`llvm::sys::`, an indexed receiver the index does not type): they are a
re-check of the file in the live worker, 1.9 to 6.5 s at p50, mostly files of
the 22-file import cycle, and are the index path's to shrink. `usize::` and
the other primitives are answered from the index (p50 2.2 ms).

The tables add about 2.7 MB to a snapshot of this graph, which a live worker
sends once, and no difference outside the spread to a whole check (12 to 14
s), to an edit through the live worker (a leaf file about 200 ms, a file of
the import cycle about 1 s) or to the worker's resident size after its first
check (about 4.7 GB).

**An edit inside an import cycle, measured** (release kals and kairo, the
kals graph of 450 files, a comment appended to the buffer): an edit of
`Server/TextUtil.k`, in a 20-file cycle, has its results in 750 to 800 ms and
is drained in 850 to 900 ms; an edit of `Tuning.k`, a leaf with 23
importers, in 150 to 170 ms, drained in about 1.1 s. The cycle's re-check is
about 480 ms (20 files) and a leaf's 19 ms. The retraction
(`retract_instances` walks the whole graph's instance registry) costs about
65 ms on every edit whatever its size, 40 % of a leaf edit. So in a cycle the
300 ms row is missed by the lockstep, which re-checks all 20 members for an
edit of one. Not built:

1. A cycle member whose edit leaves its interface hash as it was
   (IncrementalSema.md: a body edit, a comment) re-checked ALONE, against
   the other members' kept trees, as an acyclic file is: the others are
   past Typed and read nothing of its bodies. `LiveCheck::_plan` decides
   the set before the edited file is re-parsed, and the hash is only known
   after its T.
2. A retraction proportional to the edited set (an index from a file to
   the registry entries it requested or owns), and phase I of a re-armed
   member whose imports' surfaces did not change keeping its overlay.

**Outside the budget:** an edit that changes a file's set of C++ imports.
It reloads imported C++ and reports `$/progress` instead of meeting a row;
p95 is reported without it.

Every other feature falls into one of these buckets. Every request is
cancellable: a stale request for revision N while the user is at N+3 is
wasted work and must not be computed.

**Where the budget stands.** Everything answered from a snapshot or from the
text meets it: a request answered from a fresh index takes under 1 ms, and
folding, selection, signature help and on-type formatting under 1 ms from the
text. Fresh results after an edit come from the live worker (section 10): 150
to 170 ms for a leaf file of the kals graph, about 0.75 s for a file in a
20-file import cycle, in a release kals. A process per run, the fallback,
re-checks the entry's whole import graph: about 0.4 s for a small project and
41 s for the `Compiler/Driver/Kcc.k` graph (374 files) in a debug kals (9.4 s
with a release compiler, type-check only).

**The syntax pass** is a worker process that stays up and is fed buffers over
a pipe (`kals --worker --syntax-server -- [args]`, `Server/SyntaxWorker.k`;
the server's side is `kals_child_spawn` in `kals_io.h`, POSIX `pipe` +
`posix_spawn`; the Windows branch is a `TODO(WINDOWS)` that returns no child,
so the per-process path runs). The lexer, preprocessor, parser, token and
location code hold no module-level state (the process-wide natives are the
allocator recycler, logging and timing), so a fresh `CompilerInstance` per
buffer in one process gives the same answer as a process per pass. It reads
LSP-framed `{ id, file, text }` on stdin and answers `{ id, ok, parsed,
diagnostics, tokens }` on stdout; requests already queued for the same file
are coalesced, the older answered `{ id, superseded: true }` unparsed; it
exits at EOF. It runs one thread and no pool: the pool made a single-file
parse slower (343 ms against 254 ms). A pass starts on every change and a
newer change cancels it; what is coalesced is the publish (section 10). The
parser stays out of the server process: a parser crash must not take the
editor's connection with it (section 1). Keystroke to syntax diagnostics
through the server, `python3 Analyzer/Dev/bench.py syntax <kals>` (200 edits
that alternately break and repair the last line, each timed from the
`didChange` to the publish that reflects it):

| kals | file | p50 / p95 | range |
|---|---|---|---|
| release | 3,000 lines | 30.6 / 31.9 ms | 30.0 to 43.0 |
| release | 1 line | 1.5 / 1.6 ms | 1.5 to 2.4 |
| debug | 3,000 lines | 185.8 / 188.5 ms | 184.6 to 195.8 |
| debug | 1 line | 3.8 / 4.9 ms | 3.6 to 5.3 |

A release kals meets the row (p50 < 100, p95 < 200) with room; a debug kals
misses p50 on a 3,000-line file (its p95 is under 200). The worker's resident
size grows about 0.33 to 0.4 MB a pass: something a `CompilerInstance`
allocates outlives `destroy`, owner not identified (on the index side the
allocator's count shows held blocks, not retention, 0.57 to 0.61 GB per
destroyed full instance; IncrementalSema.md, "What a destroyed instance
keeps"). So the server restarts the worker after 400 passes or above a size
(section 10); over 5,000 passes in a release kals the worker's samples span
97 to 202 MB (a sawtooth) and the server's 95 to 99 MB.

Completion is served from the live worker's scope tables, not a marked
re-check, for what the tables can type (section 8).

**How the budget is checked.** TARGET. Recorded edit traces replayed against
`Compiler/`, each edit tagged by kind (body, signature, new top-level
declaration, hub file, file importing C++, import-set change), p95 per
kind; instruction counts rather than wall time as the gated number; the
worker's resident memory per run. `Analyzer/Dev/bench.py` is where this
goes.

## 12. Threads

PARTLY.

Today the server is one loop on one thread, and every heavy computation is
in a worker process (which uses the compiler's thread pool). That keeps the
loop free: nothing it does itself is more than a table lookup.

The target model, for the persistent worker and for the lookups that grow
with the project:

- **The viewport is the main thread's.** Anything about the visible buffer
  (tokens, hints, hover, completion for the cursor) is answered on the main
  loop from immutable snapshot tables, and never waits on a lock a
  background task holds.
- **Everything else is background work on the existing thread pool**
  (`Compiler/Threading/ThreadPool.k`): workspace symbols, references and
  rename across files, code-lens counts, call and type hierarchies, the
  index of files nobody has opened.
- Snapshots are immutable once published; a background task reads the
  snapshot that was current when it started, and its answer is dropped if
  the request was cancelled or the revision moved.

Not built: the server does these lookups inline today. They are linear in
the snapshot and measured under a millisecond on one indexed file; they will
not be once references span a wide index.

## 13. Cost rules

BUILT. The rules new code in `Analyzer/` is held to.

- **`didChange` is O(size of the change), not O(document).** A buffer is a
  `GapText` (`Analyzer/DocumentStore.k`): its bytes in a gap buffer, its
  line starts in a second gap array whose entries before the gap are
  absolute offsets and after it distances from the END of the text, which an
  edit before them does not change. An edit costs its own size, the lines
  it adds or removes, and the distance from the previous edit. The whole
  text is materialised (`Document::sync`) only for what reads it whole: a
  worker's overlay file (once per run), the text scanners, formatting,
  completion. Measured (`python3 Analyzer/Dev/bench.py edits <kals>`, 10,000
  single-character edits to a 1 MB buffer, debug kals): 0.08 to 0.18 ms per
  edit typing at one place and 0.05 to 0.13 ms at random positions (what is
  left is the JSON message itself).
- A request answered from a snapshot is O(rows of one file) at worst, and
  O(log n) where the rows are sorted. The worker writes `refs` sorted by
  position; when an index is installed the server decodes it once
  (`Server::index_cache`: per file the ref rows' positions and the token
  integers), `ref_at` binary-searches the line, and the token answers
  (full, delta, range) read the decoded integers rather than the JSON
  nodes. Measured (`bench.py rows`, hover on the last of 20,000 refs):
  0.06 to 0.09 ms per request (a request that reads no rows: 0.03 to 0.05
  ms). The range cut stays a linear pass over the
  decoded integers.
- Nothing per keystroke allocates per token: token data is forwarded as the
  worker wrote it.
- **Measured on the kals graph** (release kals, `Analyzer/Server/Server.k`
  open with the repo's `kairo_compile.json`, 418 files):
  requests from a fresh snapshot, 500 each, p50 / p95: hover 0.02 / 0.02
  ms, definition 0.02 / 0.02, references 0.04 / 0.04, semantic tokens full
  0.42 / 0.44 and delta 0.43 / 0.45 (8,125 integers), document symbols
  0.13 / 0.14, inlay hints 0.17 / 0.18; completion is a marked run (8.1 s).
  Installing a run's snapshot (trace line `install`): 176 KB (the graph is
  wide, so only open buffers are in it), 1.7 ms in all: JSON parse 0.9,
  the two `JsonDoc` copies (snap, idx) 0.5, index cache 0.03 to 0.09,
  publish 0.04. Not worth a binary format or lazy decoding at this size.
- **A wide graph is run without `--root`.** With it the worker would walk
  every file under the project root and then drop those rows because the
  graph is wide (walker 1.43 s + row writer 0.62 s of CPU in a 9.77 s run).
  A graph last seen wide is run without `--root` (and rerun with it if the
  run finds it narrow again): 7.26 s a run, walker 2.2 ms. The worker reports
  `timing` (`run_us`, `walk_us`, `write_us`, `assemble_us`, `unit_fids`)
  in its snapshot.
- No C++ std containers (section 17); hot paths use the language's own
  tools: `inline` on small accessors, `const` parameters so nothing is
  copied, `[T]` with `reserve`, and no string concatenation in a loop
  without `reserve`.

## 14. Logging and tracing

BUILT.

- **`window/logMessage`** carries what a person using the editor wants to
  see in the server's log: start-up and the project file found, the first
  analysis of an entry and any run slow enough to be felt (files,
  diagnostics, time), a worker that failed and why, a `kfmt` refusal. VS
  Code shows it in the "Kairo" output channel; Zed in the language server
  log.
- **stderr** carries the same lines.
- **Progress.** An entry's first analysis, and any run of an entry already
  known to be slow, shows LSP work-done progress when the client sets
  `capabilities.window.workDoneProgress`: `window/workDoneProgress/create`
  with a token, `$/progress` `begin` (title "Indexing Kairo"), `report`s,
  and `end` when the run lands or fails. The worker counts the files Sema
  has checked into its `--progress` file (one `SemaObserver::on_checked`
  per file); the loop reads it each turn and reports `N/M` with a
  percentage (capped at 99), M being the files the entry's last run read.
  On a very first run M is unknown: the begin is indeterminate (the entry's
  name, no percentage) and the reports say `N files`. Without the
  capability: one `window/logMessage` "indexing <entry>" at the start, and
  the "analysed <entry>: N files, D diagnostics, T ms" line at the end.
- **`<scratch>/trace.log`** (the server's scratch directory under the
  system temp directory, `kals-*`) has one line per message in and out,
  each run's start and end, and the client's capabilities at start-up. It is
  what a report of "the editor shows nothing" needs: an editor shows what it
  drew, not what it was told.

## 15. C and C++ beside Kairo: the clangd bridge

BUILT (smoke.py `bridge`, clangd on PATH): a jump from C++ opens the `.k`
file at the declaration's line (the layout below).

- **Which files.** At `initialized`, and on the Sema debounce after any
  C/C++ file changes (buffer, save or watched file): the `file`s of
  `<project>/compile_commands.json` (or `build/compile_commands.json`),
  else every C/C++ file under the root (dot-directories, `build/` and
  `node_modules/` skipped), are read (open buffers first) for
  `#include "*.k"`; a name resolves beside the including file, then under
  the project root. Quoted includes of other headers are followed too
  (a.cc includes b.h, b.h includes c.k), `BRIDGE_INCLUDE_DEPTH` (8)
  headers deep and at most `BRIDGE_INCLUDE_MAX_READS` (4000) header reads
  per scan, each header read once a scan; textual, so `#ifdef __cplusplus`
  is not evaluated, and angle includes and `-I` roots are not followed. A
  source is read again when it, or a header its last scan read, is
  reported changed.
- **The header** is written by a separate header job (section 3), not by
  the index run: emitting bodies can ICE where checking does not, and a
  crash must cost the header, not the index. One header job at a time, on
  the Sema debounce, for each included file that is due: due when first
  found, and on any change to it or to a file its last check read (`deps`,
  which covers a module it re-exports from). Order (a job is a
  second or two, so 55 included files take about 90 s in scan order and
  the file being looked at could be last): a `.k` open in the editor
  first, then one included by the C/C++ source reported changed most
  recently (the last `BRIDGE_RECENT_SOURCES` reported, Tuning.k), then scan
  order (`bridge_next_`). A header an earlier session wrote is mapped at
  once through the overlay merge below, stale until its job comes round.
- **`#line`.** `--emit-headers-line-directives` (hidden; Driver.md) puts
  `TextSink` in line mode: each output line is buffered and written under
  `#line N "abs/file.k"` naming the Kairo file and line of its first token
  with a location; a line with none (pragma, lowering helpers, namespace
  braces: anything anchored at offset 0 or unlocated) sits under
  `#line <its own line> "<header>"`. A directive is written only where the
  attribution changes. The other two paths are unchanged: a plain
  `--emit-headers` has no directive (`Tests/Codegen/emit_headers_plain_no_line.k`),
  and kcc's token injection does not use `TextSink`. Tests:
  `Tests/Codegen/emit_headers_line_directives{,_cxx}.k`.
- **Layout.** kals passes `--emit-headers-layout` (hidden; implies
  the line mode above, which keeps its own output for its tests). clangd
  reports a header location by its PHYSICAL line, so `TextSink` records the
  lines and `finish_layout` places each one from the module's `.k` file on
  the physical line its declaration has there (a line is attributed to the
  lowest Kairo line among its tokens: the name precedes parameters and
  result). Everything the emitter invents before the first Kairo line, and
  every forward-declaration chunk, goes to `<header>.prelude` beside the
  header, included by absolute path from line 1 (clangd may present the
  header under the `.k` name, so a relative include would resolve wrongly);
  `_Pragma("once")` opens line 2. A line that is behind, or has no Kairo line
  (closing braces, glue), continues the current physical line; directives
  take a fresh one. The one reordering: a namespace-scope chunk of plain
  prototypes (no body, no `=`; an `extern` variable counts) is split
  into `namespace n { proto; }` pieces, each moved up to its own Kairo line
  when that line is at namespace scope and nothing it may need is placed
  later, because the emitter writes functions after every class. Types are
  forward-declared in the prelude; a later class (a class template too) whose
  `Name::` it spells is a barrier; an explicit specialization (an enum's
  `__kairo_niche<E>`), an alias, a variable or an extern variable bars only
  the prototypes that spell its name as a whole identifier, and every
  prototype with text C++ evaluates where it is declared (`noexcept(`,
  `requires`, a `decltype(` other than the size_t spelling
  `decltype(sizeof(0))`); any other namespace-scope declaration bars every
  prototype (fail closed). One `#line N "file.k"` goes on the line
  before the first Kairo line placed in order, when there is room, so
  presumed and physical lines agree from there.
- **Lines a declaration would lose (layout only).** A line is
  attributed to its lowest Kairo line, so text anchored at an earlier
  declaration took the line of whatever followed it on the same output line.
  `TextSink` therefore breaks, in layout mode only, after each comma of an
  `enum class` body (the enum's `};` is anchored at the enum, which pulled
  every variant onto the enum's line; an enum the compiler mints, an ADT's
  `__kairo_Tag`, is left whole, since its variants share the Kairo lines of
  the factories C++ calls), and after an access specifier (`private :` is
  anchored at the class, which pulled the field after it onto the class's
  line). In `finish_layout`: a forward declaration in a chunk with other text
  (a concept or a guard beside it, so not a prelude chunk) claims no line
  when its definition then gets that line, which is the line clangd jumps
  to; one whose definition does not (placed out of order) claims it as
  before, settled over a few passes of the placement (`_lay_`); a forward
  declaration of a name the compiler mints (`__kairo_ext_T`) never claims
  one. Text that declares a minted name (an ADT's payload structs, its tag,
  its anonymous union, `__kairo_` members), with its whole body, claims no
  line either: it carries its variant's Kairo line, which the factory C++
  calls wants; an extend block's `__kairo_ext_T` struct claims none but its
  functions do. `Analyzer/Dev/layout_lines.py` (libclang under kcc's flags) measures, for
  each matched Kairo declaration, whether the line of the C++ declaration
  clangd jumps to (the definition when the header has one) is its `.k` line;
  the driver's `-v` counter reports the `///` docs placed in place and
  dropped (records, the minted ones included). No declaration that is on its
  line is moved off it by the line breaks above (`--on-set`, compared per
  declaration).
- **Out-of-line bodies (layout only).** The emitter writes inline and
  template bodies after every class (and an extend block's functions after
  its struct), so clangd's definition would be that later line while the
  declaration sits on the `.k` line. `finish_layout` (`_mark_drops_`) leaves
  such a definition out, so clangd's jump falls back to the declaration,
  when all of these hold: its chunk is one `namespace n {`, a function head
  ending in `{`, the body and the closers, with no directive; its head
  claimed no line; its Kairo line is claimed by its declaration (for a
  member, a line inside a class that spells its name and is not a friend
  or the class head; for a free function, a prototype whose signature,
  without `inline` and attributes, is the head's). C++ in the including
  file can need some bodies, and those are kept: `constexpr`, `consteval`,
  a deduced `auto`, an explicit specialization (`template<>`), `static` or
  `extern` heads. Hover, docs and completion read the declaration. What is
  lost: clangd no longer reports errors that only an instantiation of a
  dropped template body by the user's C++ would show. Counted in the
  driver's `-v` `emitted header` line (`out-of-line bodies: N left out, M
  kept as needed`). Measured as above, 27 builtin headers: 525 declarations are on their `.k`
  line and 58 have the definition elsewhere (55 of them bodies kept as
  needed, nearly all `intrinsics.k`'s consteval traits; the other 3 are two
  constructors and one extend method, below; 348 bodies are left out); the
  `///` docs clang attaches are 503, with 17 dropped and none on the wrong
  declaration; 59 corpus headers: 274 on their line and 1 not. The entity
  set (libclang USRs, locals aside) of every header is unchanged; every
  header compiles standalone and all in one TU but `base/alloc.hh`, whose one
  remaining error is the `prot` `scope_push` it calls, and `-fsyntax-only`
  of the 60 corpus C/C++ sources through the overlay gives the same
  diagnostics. Plain `--emit-headers`, the line-directive mode and kcc are
  byte-for-byte unchanged. Tests:
  `Tests/Codegen/emit_headers_layout_bodies.k` (no body for an inline
  method, a function template, an extend block's function or an inline
  function after a class; a consteval body kept, and a C++ `static_assert`
  on it through the header); smoke `bridge_bodies` (clangd's definition of
  each of the first three is its `.k` line, hover on the method shows its
  doc, the `static_assert` holds).
- **The module's own file.** `finish_layout` lays a header out against the
  TU's own `.k` file (`TextSink::home_path`, from `EmitCXXHeader`), not the
  file most lines are attributed to: a small module that instantiates an
  imported template (`Panic<i32, Shared>`) has more lines from that
  template's file, and the prelude then ended inside a type-id guard
  (`#ifndef` in the prelude, `#endif` in the header; neither compiled). The
  prelude also never ends inside a conditional it opens. Test:
  `Tests/Codegen/emit_headers_layout_home.k`.
- **Limits that remain.** A body kept as needed (above) and a constructor
  whose head is anchored at its class's line (its member initializers name
  minted helpers) stay on a later line; a line a guard directive takes (the
  witness `#ifndef`/`#define`/`#endif`, between one-line extend blocks on
  consecutive lines: 15 of `hash.k`'s `extend` blocks); members the emitter
  writes after the class's others (an `eval if` block inside a class); a
  declaration on Kairo line 1 (the include's line); a class the emitter
  orders after a later class (dependency order, ADT records). Columns are
  not aligned. Tests: `Tests/Codegen/emit_headers_layout.k` (physical lines
  by `sed -n Np`, and clang naming the `.k` line through the header),
  `Tests/Codegen/emit_headers_layout_lines.k` (variants, a field after
  `private :`, a function above the enum it names); smoke `bridge_layout`
  (clangd's definition of a variant, of a function above the enum it names
  and of one after a class; hover on a variant).
- **`-D`.** An entry's `-D` is a Kairo macro and never reaches
  clang (Driver.md: `--cxx-define` is clang's): `kairo x.cc -DFOO` compiles
  a C++ file that `#error`s under `FOO`, `--cxx-define FOO` trips it. The
  `.clangd` words are the C++ words the entry's own invocation compiles
  with (`cxx_driver_words`), so they carry its `--cxx-define`s and no
  `-D`: clangd sees the C++ as that build does. (kcc's own command-line
  `-D` is clang's; that is kcc's command, not the entry's.) The header is
  emitted with the entry's `-D`s applied, since they act on the Kairo
  source. The bridge says nothing about it.
- **Doc comments (layout only).** After placement, `finish_layout`
  (`TextSink::_docs_`) puts the `///` block above each declaration placed
  on its own Kairo line on the lines that block has in the `.k` file, as
  written (C++ `///` lines, a Doxygen comment clangd shows as-is; a
  trailing `\` is cut, since it would splice the declaration into the
  comment). The block is the one kals' hover reads (`Hovers.k` `doc_`):
  attribute lines between it and the declaration are passed over, a bare
  `//` ends it, a `/// ---` banner is not a doc. Only when every one of
  those lines is empty in the header: nothing is moved to make room.
  clang attaches a comment to the next declaration only across whitespace
  (no `;{}#` between), so a declaration line that opens with its
  namespace (`namespace n { class C {`, a moved prototype) has the opener
  moved to the line above the comment, across nothing but the empty lines,
  and the one `#line` of the layout, if it is among them, moves above the
  block (or is dropped: under the overlay the header is named by its `.k`
  path anyway). A class whose block has no room (a doc on lines 1-2, which
  the prelude include and the pragma hold; a class placed out of order)
  gets the block on its forward declaration in the prelude instead: clangd
  shows the doc of any redeclaration. Anything else is dropped. Counted per
  header in the driver's `emitted header` log line (`-v`); over the 28
  builtin module headers: 524 in place and 32 dropped (a doc with no
  room to move up, nearly all on functions the emitter writes after every
  class). A user `--emit-headers`, the line-directive mode, and kcc are byte-for-byte
  unchanged (finish_layout runs only in layout mode). An enum's variants
  are on their own lines, so their docs are carried and counted
  like any other. Not carried: interfaces (no C++ declaration). Smoke: `bridge_docs`
  (clangd hover on a class, a method, a function and a struct from C++).
- **Unchanged headers are not rewritten** (line mode only): the header is
  compared with what is on disk first. A changed header and its prelude are
  written to a temporary in the same directory and renamed into place
  (`AtomicFile::publish_bytes`). A `.k` with errors writes nothing,
  so its last good header stays.
- **overlay.yaml** maps each included `.k` (real path) to its header, with
  `'use-external-names': false` at the top and `'use-external-name': false`
  on each entry (clang's per-entry key is singular; the plural is an
  "unknown key" error on clang 22), each path a single-quoted YAML scalar.
  Shared by every kals on the root (two editors), so a write is a
  merge, never one process's view: the entries on disk whose `.k` and
  header both exist are kept beside the process's own; for a `.k` both
  name, the newer header file wins (the process whose job ran last), so
  two processes converge instead of taking turns; entries whose `.k` or
  header is gone are dropped. Sorted by `.k` path, so equal sets are equal
  text, and written only when that text differs from the file, to a
  temporary in the same directory and renamed into place
  (`AtomicFile::publish_bytes`), so clangd never reads a partial file. The remaining race, a write landing between another
  process's read and its rename, is undone by the loop: every
  `BRIDGE_OVERLAY_CHECK_MS` (2 s) it compares the file's mtime with the one
  it last wrote or read and merges again when it changed. Safe because the
  merge only ever adds back entries whose files exist and both processes
  compute the same text from the same disk state, so it reaches a fixed
  point (smoke `bridge_shared`: a clobbering write is undone while idle;
  two servers on one root end with every entry and then leave the file
  alone). Limit: an entry for a `.k` nothing includes any more stays while
  its header exists (harmless: clang reads it only for an `#include` of
  that path).
- **`.clangd`**: written when absent or when its first line is kals' marker
  (`# Written by kals, ...`), and only when its text changed (clangd reloads
  its config on every write); written to a temporary in the same directory
  and renamed into place (`AtomicFile::publish_bytes`). Two fragments, every word a single-quoted
  YAML scalar:
  1. for every file, `CompileFlags: Add: [-ivfsoverlay, <overlay>,
     -I<cache>]` (the `-I` so a header's own includes of other generated
     headers resolve);
  2. `If: PathMatch: [<each C/C++ source under the root that reaches a
     .k, relative, regex-escaped>]`, `CompileFlags: Add: [<kcc's driver
     words for that source>]`, one such fragment per distinct set
     of words. A source's set is the one the header job of the
     first `.k` it reaches reported, so sources of entries with different
     flags get their own: `cxx_flags` for C++ (and headers), `c_flags`
     (`c_driver_words`, what kcc gives a `.c`: the C roots and C `-std`)
     for a `.c` / `.m`. Until a source's own `.k` has a finished job it
     takes any file's set for its language (at a restart every job is due
     again, and the source must not lose kcc's words meanwhile), and while
     no job has reported words at all a `.clangd` kals wrote is left as it
     is. The header job's worker reports them
     as `cxx_flags` (`CompilerInstance::cxx_driver_words`, the
     `_native_words` kcc compiles a `.cc` with: the sysroot's libc++ and C
     roots, kcc's resource dir, `--target`, `-std`, the runtime root as
     `-I`, the entry's `--cxx-flags`; a Kairo `-D` is not forwarded to
     clang, so it is not among them). Needed because the header's prelude
     includes the runtime's `rt/*.h` (found only under the runtime root)
     and standard headers: under the host's libstdc++, `<type_traits>`
     declares `__make_unsigned`, clang stops treating that name as its
     builtin, and `rt/intrinsics.h` does not parse. The prelude cannot be
     made self-contained: the standard library is chosen for the whole
     translation unit. Scoped, because the words carry kcc's `-std` and
     standard library: a `.c` file given `-std=c++23` is a clang error, and
     a C++ file that includes no `.k` keeps its own command.
  A `.clangd` a person wrote is left alone; the fragments are logged
  (`window/logMessage`) once per distinct text, however many bridge passes
  run (one per finished header job), and not at all when the file
  already contains the overlay path and every one of kcc's words.
  Limits: a source outside the root is not covered by the root's
  `.clangd`; a source past the include bounds above, or reaching a `.k`
  only through an angle include or an `-I` root, gets the overlay but not
  kcc's words (`'rt/crash.h' file not found`); a source
  that reaches `.k` files of two entries gets the first one's words; a
  `.c` that includes a `.k` directly gets the C set and then fails on the
  C++ header, as kcc rejects it (CL001E). Smoke: `bridge_real` (a `.k`
  with a std import, an ffi C++ import and a class; bundled clang with
  the `.clangd` words, clangd's diagnostics on two includers and a `.c`,
  and its jump to `test.k`); `bridge_through` (a `.cc` through a header,
  a `.c` through an `#ifdef __cplusplus` header with the C set, two
  entries' `--cxx-flags` kept apart; clangd clean on both and its jump
  from the `.cc` to `c.k`).

Not verified: clangd picking up a regenerated header while it has the
C++ file open (only a fresh clangd was driven), clangd reloading a
rewritten `.clangd` (new includers, new flags) while running, a
`compile_commands.json` whose own flags conflict with kcc's (`-std`,
`-stdlib`), and any real editor. Verified with clangd 23 (system) on kcc
22's resource dir: no mismatch seen.

Measured (debug kals, loaded machine): a header job for a 10-line file is
about 0.4 s; it also writes the builtin modules' headers, unchanged after
the first run.

**clangd ignores `#line`** (closed by the layout). clang's diagnostics use
presumed locations, so `clang++ -fsyntax-only -ivfsoverlay overlay.yaml
b.cc` names `a.k:6` for an error on `a::add` (smoke-checked). clangd's
go-to-definition reports spelling (physical) locations: without the layout it
gives line 147 for `add` at a.k line 6; with the layout it gives 5 (0-based),
the declaration's own line, smoke-checked when `clangd` is on PATH (else the
check reads the header's physical line). kcc's own diagnostic adapter also
reports spelling locations; it does not use this mode.

The design the above implements:

**The problem.** A project mixes `.k` with C and C++. kcc compiles
`#include "foo.k"` in a C++ file by generating the declarations Kairo
exports (Interop.md, the include design). clangd, running beside kals in the
same editor, knows nothing of that: it reports the include as a missing file
and every Kairo name as undeclared.

**The design.** kals keeps, for every `.k` file a C or C++ file of the
project includes, a generated header on disk in a cache directory, and tells
clangd to read it in place of the `.k`:

1. kals already runs the compiler per entry. `--emit-headers <dir>` exists
   and writes each module's C++ interop header. The worker passes it a cache
   directory (`<project>/.kairo/clangd/`), so each run refreshes the headers
   of the modules that changed.
2. clangd is told through the standard channel it already reads,
   `compile_commands.json` / `compile_flags.txt` plus a `.clangd` fragment
   that kals writes: an `-include`-free mapping using clang's own
   `-ivfsoverlay <file.yaml>`. The overlay YAML maps each `foo.k` path to
   the generated `foo.k.h` in the cache, so `#include "foo.k"` resolves to
   real C++ declarations with no change to the user's sources and no
   patched clangd.
3. kals rewrites the overlay only when the SET of mapped files changes;
   a changed header replaces the old one under the same path (a temporary
   renamed into place), and clangd's own file watching picks it up.
4. **A jump from C++ lands in the `.k` file, never in the generated
   header.** Two parts, both needed:
   - **Only the language server's overlay headers carry `#line`.** The
     emitter has a mode, off by default and switched on by kals alone, in
     which it writes `#line N "file.k"` before every declaration, naming the
     Kairo declaration's own line and file, so every location clang records
     for it is the Kairo source. Text the emitter invents with no Kairo
     counterpart (guards, includes, glue) sits under a `#line` naming the
     header itself. The other two paths never emit `#line`, on purpose:
     - `kcc main.cc` with `#include "foo.k"` does not go through text at
       all: it injects tokens whose locations already point into the Kairo
       file, column-accurate. The tokens skip the preprocessor, so a
       directive there would be wrong as well as useless.
     - A header the user asks for (`--emit-headers`) is for sharing, or for
       a system C++ compiler. It stays plain C++ with no directives. kcc is
       the supported way to get Kairo locations.
   - The overlay YAML is written with `'use-external-names': false`, at the
     top level and on each entry, so clang reports the mapped file under its
     `.k` name and not the cache path it was redirected to.
5. **kals owns the overlay's freshness.** It tracks every `.k` file that a C
   or C++ file of the project includes (scan of the `compile_commands.json`
   sources for `#include "*.k"`, re-scanned when one of them changes), and
   regenerates that file's header on every edit of the `.k` file or of a
   module it re-exports from: on the edited BUFFER, not only on save, with
   the same debounce as a Sema run. A header whose text did not change is
   not rewritten, so clangd is not made to re-parse for nothing. A `.k` file
   that no longer parses keeps its last good header.

Open: whether clangd honours `-ivfsoverlay` from `.clangd` `CompileFlags:
Add` on every platform (it is a clang driver flag, so it should); the cost
of emitting headers on every run of a large entry (emit only for modules a
C/C++ file includes, found by scanning the project's `compile_commands.json`
sources for `#include "*.k"`).

## 16. Compiler hooks

BUILT.

| Hook | Where | Why |
|---|---|---|
| `Tooling::SemaObserver`, `FrontendOptions::sema_observer` | `Compiler/Tooling/SemaObserver.k`, called from `FrontendAction::_sema_finish` | `on_checked`: the one point where names and types are resolved and no lowering has rewritten the tree (`SemaPhase::Checked`, where `--print-sema` dumps). `on_lowered`: the same TU after its lowerings and mono, same thread, always called (`sc->phase` says how far it got); kals writes a file's rows there, once the layout query can answer an ADT. `ParseAPI` returns a tree that has been lowered, with its `SemaContext` destroyed |
| `--check-past-syntax-errors` (`FrontendOptions::check_past_syntax`), `ASTContext::syntax_skipped`, `FunctionDecl::body_recovered`, `TranslationUnit::recovered_bodies` | `Compiler/Driver/CompilerRecovery.k` (called from the post-parse gate of `FrontendAction::run`), `DeclParse::_parse_fn_body`, `Sema::run_to` | the index run over a graph with syntax errors (section 9). The worker passes the flag (never the syntax pass); `on_checked` drops a `syntax_skipped` TU and reports a TU with recovered bodies as `partial`. `KAIRO_DEBUG_SYNTAX_RECOVERY=1` prints what was admitted, skipped and dropped (for `Scripts/syntax_recovery_diff.py`) |
| `SourceManager::stage_overlay` | `Compiler/Location/SourceManager.k` | what both index workers use for the editor's buffers: the bytes are given to the path where the graph first loads it, so file ids (and what is ordered by them, diagnostics among it) are a fresh `kairo` run's, whatever buffers are open |
| `SourceManager::load_overlay`, `VirtualFileManager::bind_path` | `Compiler/Location/SourceManager.k`, `Compiler/Support/FileIO/VirtualFileManager.k` | a virtual buffer under a real path, so a later load of that path (the entry or an import) reads the buffer. Import resolution still probes the disk for existence |

`TypeUtil`'s constructor and `str`, `NameLookup::ctx_of`, `DiagLabel::Style`
and `ParseOptions`' fields are `pub` for the same reason.

For completion (section 8):

| Hook | Where | Why |
|---|---|---|
| `AccessCheck::refuses(d, through, f)`, `AccessCheck::visibility_of(d)`, its constructor `pub` | `Compiler/Sema/Resolve/AccessCheck.k` | whether a use of `d` inside function `f`, reached through a value or type, is one the pass refuses, with nothing reported (the pass's own `_check`, its report sites recording instead: the marker path's access filter); and a declaration's visibility as the pass reads it (the tables' `vis`) |
| `MemberLookup`'s constructor and `extensions_of_decl`, `SemaContext::sees_extension_file`: `pub` | `Compiler/Sema/Resolve/MemberLookup.k`, `Compiler/Sema/SemaContext.k` | the `extend` blocks of a record that a file sees (the marker path's items; a block's `sees`) |
| `word_token_kinds()` | `Compiler/Token/TokenKind.k` | every kind the lexer makes of a word (the enum cannot be iterated: its values are the spellings' hashes); spelled by `token_kind_to_readable_string` |
| `LangAttrs::usage` / `targets` / `summary`; `LangMacros::known` / `usage` / `summary`; `LangIntrinsics::known` / `usage` / `summary` | `Compiler/AST/LangItems.k` | how an attribute or a builtin macro is written with its arguments, what an attribute may stand before, and one line on what each does, beside the rows `known` already lists |

## 17. Source conventions

`Analyzer/` uses Kairo containers (`[T]`, `{K: V}`) and, where an LLVM API
wants an `ArrayRef`, `llvm::SmallVector`. No C++ std containers, so the tree
needs no migration pass when the compiler drops them. The two exceptions are
compiler signatures: `CompilerInstance`'s word constructor and
`ImportOverlay::collect_rows` take a `std::vector`.

### Layout

The server is one class, `Server`, declared in `Server/Server.k` (its state,
the loop and the message router) and split by responsibility over
`extend Server { ... }` blocks, one file each: `Output.k` (responses,
notifications, log, trace, progress), `Lifecycle.k` (initialize and the
capabilities), `Scheduling.k` (entries, jobs, parked requests), `Workers.k`
(launch, reap, installing a snapshot), `Diagnostics.k` (publishing, the
syntax pass), `Lookup.k` (reading a snapshot's rows), `Features.k` (the
row-answered requests: hover, definition, references, links, inlays,
rename), `Tokens.k`, `Structure.k` (symbols, folding, selection, workspace
symbols), `CodeActions.k`, `Navigation.k` (call and type hierarchy, lenses),
`SignatureHelp.k`, `Formatting.k`, `Completion.k` (the request, imports,
the marker path), `IndexCompletion.k` (completion from the index),
`ClangdBridge.k`, and `TextUtil.k` (free text helpers). Not extensions:
`CompletionSite.k` (where a completion is asked, read off the text),
`CompletionWords.k` (keywords, attributes and builtin macros from the
compiler's tables) and `DeclTables.k` (an entry's declaration tables,
decoded). The indexer is the same shape: `IndexWalker`
in `Index/Indexer.k` (state, classification, the visits) with `Tokens.k`,
`Refs.k`, `Hovers.k`, `CompletionItems.k`, `Tables.k` (declaration tables
and scope rows), `Bases.k`, `Inlays.k`, `Macros.k` and `Writer.k`
extending it; `Index/Snapshot.k` holds the row types and the
column constants (`REF_*`, `BASE_*`, `LINK_*`, `MACRO_*`, `DC_*`, `TB_*`,
`SCOPE_*`) that both the writer
and the server's reader name; `Index/Legend.k` the token types and modifiers.

An extension is visible in a file only if that file imports the file that
declares it, so every file of `Server/` imports every other one
(`import Server::X::*`), and likewise in `Index/`. Members the extension
files share are unmarked (`prot` under `Analyzer/module.k`), never `priv`.

Two compiler limits shape this: an `extend` of a
class that derives from `RecursiveASTVisitor` is not given the base's `prot`
members, so the walker's extensions read `ctx` through `ast_()`; and C++
record definitions follow import order, not field dependencies, so
`Index/Snapshot.k` is a leaf (it imports none of its siblings) and is the
first import of every file that holds its rows by value.

### Constants

Every wire value has one named definition: `Analyzer/Protocol.k` (method and
notification names, the JSON-RPC version, error codes, code-action kinds,
commands, the LSP enum values the server writes: `MessageType`,
`DiagnosticSeverity`, `SymbolKind`, `CompletionItemKind`, `InlayHintKind`,
`DocumentHighlightKind`, `TextDocumentSyncKind`, `FoldingRangeKind`; the
semantic-token stride; the LSP objects' member names `K_*` and kals'
`initializationOptions` names `OPT_*`; and one writer per repeated shape,
`write_lsp_position` / `_range` / `_location_raw` / `_text_edit_raw`),
`Index/Legend.k` (token types, modifiers and their bits), `Index/Snapshot.k`
(row columns, and the snapshot's member names `SK_*`),
`Index/WorkerKeys.k` (the live and syntax workers' request and answer
members, `RQ_*` / `RP_*`) and `Analyzer/WorkerArgs.k` (the worker command
line, `WA_*`, and the compiler flags the server adds, `CF_*`). Kairo's file
and path spellings (`module.k`, `.k`, `::`) and the `--emit-headers` header
path are the compiler's, in `Compiler/Resolution/ModulePath.k`. Every tunable is in
`Analyzer/Tuning.k`, each with what it trades off. A literal that is only
itself (0, 1, a byte compared against, a separator inside one function)
stays a literal.

## 18. Testing

`python3 Analyzer/Dev/smoke.py` writes a project, drives a server over stdio
(`Analyzer/Dev/lsp_client.py`), and checks every BUILT section above: each
request, the token modifiers, hover content, hints, completion in each
position, imports, f-strings, deltas, cancellation, logging, the same
workspace through a symlink, a crashing worker (`KAIRO_DEBUG_FORCE_ICE`),
the syntax-only pass (its errors before the run, an older run not
overwriting them, lexical tokens, the run's diagnostics replacing them; runs
held back by `KALS_DEBUG_INDEX_DELAY_MS` so the order is certain),
progress, incremental edits against a reference copy (`$/kals/text`; insert,
delete, multi-line, start and end, CRLF, UTF-16 columns, 1000 random edits),
and the macro hover and both macro actions (the expanded edit applied and
checked), enum/union/variant hover, "Generate interface" (the edit
applied and the file type-checked again), and the clangd bridge (header,
overlay, `.clangd`, an unsaved edit, the bundled clang through the overlay,
and clangd's definition when `clangd` is on PATH), and the persistent
syntax worker through the server (diagnostics with both debounces at 5 s,
a killed worker still answering that edit and being restarted, 300 edits at
once ending on the final revision's diagnostics), and the live index worker
(`live()`: a first check, an entry edit re-checking one file, a leaf's first
tier and its importer after it, a signature edit whose importer gets its
error at its turn and loses it with the fix, a buffer that does not parse
going to a process and coming back, a queue held back
(`KALS_DEBUG_LIVE_SLICE_DELAY_MS`) and pre-empted by a second edit, rename
refused while files are pending, a wide graph answering a newly opened file
with nothing re-checked, and a DIFFERENTIAL session: the same edits against
a process-per-run server, the two installed snapshots (`$/kals/snapshot`)
equal in rows, diagnostics and files), launches refused on purpose
(`launch_failures`, `KALS_DEBUG_LAUNCH_FAIL`: an index run, a fallback
syntax pass and a header job are each retried), a stale fallback syntax pass
dropped (`stale_syntax`, `KALS_DEBUG_SYNTAX_DELAY_MS`), a project reload and
an ad-hoc entry retired during a run (`entry_identity`), a request held
for a candidate entry's first run (`first_pending`), the session
lifecycle (`lifecycle`), and completion from the index (`completion_index`:
a plain name in a buffer that parses and in one that does not; the cursor
inside a name, as a deletion leaves it; a local of a closed block and a
closure's parameter; `priv` and `prot` members from another file and from
their own; an extension member where its file is imported and where it is
not; inherited members; a module's names; a call's result; a local typed
since the last index and its members; subscripted and parenthesised
receivers from the tables, a type's own `op []` falling back to the
compiler; `self[i].`, `(*p).`, `x?.` and a step named with a trailing
underscore from another file, from the tables; a primitive's `::` (its
limits, an `extend i32` static where its file is imported and not where
it is not, and the same from the compiler); the type of a local typed
since, from a construction or a literal and not from a call; a `case`
binding typed since; a macro before an `!` already
written; keywords at a statement's start, in a type position and at
file level; nothing where a name is declared, in a comment, in a string;
a trigger character where it does not mean its trigger; attributes and
those a function takes; the file's and the builtin macros; import paths
and names; C++ and C headers and a header's directory; and the same lists
from the compiler with the index path off). `--only a,b` runs just those checks while
iterating. The gate is the suite in BOTH modes: run plain it is live, as
the server is (`smoke.py` sets `KALS_LIVE_CHECK=1` for every server it
starts), and with `KALS_LIVE_CHECK=0` it is a process per run (the checks
that are about one mode name their own). `Analyzer/Dev/live_bench.py` times an edit on a real
workspace. `Analyzer/Dev/bench.py` measures the costs of section 13 (`edits`, `rows`) and the syntax row of section 11 (`syntax`). After a change it waits for `$/kals/analysed`
rather than for time to pass, and it retries `ContentModified` as an editor
does, so it holds on a loaded machine. It is not in `Tests/`.

## 19. Editors

`kals` is part of the toolchain: `TOOLCHAIN` and `STAGED` in `build.py`, so
`python3 build.py --debug` builds and stages it beside `kairo`, `kcc`, `kld`,
`kfmt` and `ksys`, and a release build ships it (`Scripts/package_release.py`
`SHIP_BIN`).

The clients are in the `kairo-lsp` repository: `vscode/`, `zed/`, `nvim/`,
and the shared `tree-sitter-kairo/` grammar. Each finds `kals` on `PATH` and
draws `overloaded` underlined, `dispatched` underlined and italic,
`extension` italic, primitives in the keyword colour, the `&` of a call
argument in its parameter kind's colour, and macros in amber (section 5,
the style table).

**Completion after a deletion.** kals answers a request wherever
the cursor is in or after a name, however it got there; whether a request
is SENT on a deletion is the editor's. VS Code asks on a deletion only
while the list is showing: the extension (0.9.1) runs
`editor.action.triggerSuggest` after a single-line deletion by the
keyboard that leaves the cursor in or right after a name
(`kairo.completion.triggerOnDelete`, on by default; not after an undo, a
multi-cursor edit or a paste). Zed and Neovim have no hook an extension
or this plugin can use: Zed re-queries on a deletion only while its menu
is open (`show_completions_on_input` governs typing alone), and in Neovim
it is the completion plugin's (nvim-cmp asks on every text change once
`keyword_length` characters are before the cursor; blink.cmp has
`completion.trigger.show_on_backspace` and
`show_on_backspace_in_keyword`; the built-in
`vim.lsp.completion.enable(..., { autotrigger = true })` asks on trigger
characters only). UNVERIFIED: written from memory of those editors'
settings, neither run nor checked against their current documentation;
the Zed extension and the Neovim plugin in `kairo-lsp` configure nothing
about completion.

Known: Zed 1.27 does not request inlay hints from kals although both sides
advertise them and the setting is on (VS Code shows them). Unsolved.
By reading (no Zed run): kals' side is as LSP 3.17
requires. `initialize` advertises `inlayHintProvider: {resolveProvider:
false}` statically (no dynamic registration involved), hints are answered
for any range, `kind` is 1 or 2 or omitted, and
`workspace/inlayHint/refresh` is sent only when the client says it
supports it (it is a nudge, never a precondition). The Zed extension
(`kairo-lsp/zed`) has no setting that could turn hints off. What is left
is Zed's side, which is off by default. The settings to try, in Zed's
user `settings.json`:

```json
"inlay_hints": { "enabled": true, "show_type_hints": true, "show_parameter_hints": true, "show_other_hints": true },
"languages": { "Kairo": { "inlay_hints": { "enabled": true } } }
```

then `editor: toggle inlay hints` once, and `dev: open language server
logs` -> kals -> RPC messages to see whether `textDocument/inlayHint` is
sent at all.

## 20. Not implemented

- Completion: ranking by expected type, postfix completions, auto-import on
  completion, user-defined attributes after `@`; an indexed receiver's
  element type and a C or C++ receiver from the tables (both go to the
  compiler).
- Assists: extract function or variable, inline, fill match arms, add
  missing members, generate impls.
- More inlay hints: chained-call types, closure return types, closing-brace
  labels.
- Editing help: join lines, matching brace, move item up or down.
- Hover actions.
- A workspace-wide symbol index for files nobody has opened.
- Unused and inactive code greyed out, with a quick fix (section 5).
- Background threads for cross-file lookups (section 12).
- The live worker (section 10): a per-file install path in the server for a
  wide graph, a memory footprint that needs no periodic restart, pipes on
  Windows.
- The clangd bridge (section 15, "Limits that remain").
