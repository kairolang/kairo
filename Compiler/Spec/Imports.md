# Imports

How a name written in one file comes to refer to a declaration in another: how an import path finds a file, how a library is named, and how phase I turns a file's imports into the overlay that name lookup reads. Imports of C and C++ headers (`ffi` imports) share phase I and are described in [Interop](Interop.md#ffi-imports). What an import means to a Kairo programmer is in the language reference ([imports](README.md#language-reference), [modules](README.md#language-reference)).

## Model

Imports are erased at name resolution. After N and ChainBinding every use site holds a `*Decl`, and the declaration knows its own home through its DeclContext parent chain. No pass after sema reads an `ImportDecl` ([invariants](Pipeline.md#invariants)). Codegen regenerates, per TU, the declarations a C++ header would have provided, from those `*Decl` links ([EmitPlan](Codegen.md#emitplan)). The only `#include` lines in emitted C++ come from `ffi` imports, plus `<new>` where a class's derived assignment rebuilds a value in place ([Codegen](Codegen.md#emitplan)).

What each stage contributes:

| Stage | Import work | Code |
|---|---|---|
| PP | resolves import paths to file ids and stamps the node; the only writer of path to file | `Compiler/Preprocessor/FileImportIndex.k`, `Compiler/Resolution/` |
| Index | hoists declaration heads for `<` disambiguation; imported generics are found through import edges | `Compiler/AST/Context/GlobalDisambigTable.k` |
| Parse | builds the AST and freezes one `SymbolTable` per scope | `Compiler/Parser/ASTParse.k` |
| I | folds each imported file's frozen table into this TU's overlay | `Compiler/Sema/Resolve/ImportResolution.k` |
| N, T, ChainBinding | read the overlay like any other scope; imports are invisible to them | [Name resolution](NameResolution.md#name-resolution), [Chain binding](TypeResolution.md#chain-binding) |
| EmitPlan | plans the per-TU C++ interface from resolved links | [EmitPlan](Codegen.md#emitplan) |

Sema runs the pipeline per file in import-DAG order, so an imported file's overlay is complete and its types are canonical before an importer reads them ([phase barriers](Pipeline.md#phase-barriers)).

## Import forms

One grammar, `Compiler/Parser/Shared/ImportGrammar.k`, serves the parser, the preprocessor and the dependency scanner.

| # | Form | Example | Binds in the overlay |
|---|---|---|---|
| 1 | plain | `import foo` | `foo` to a module handle for foo's `ModuleDecl` |
| 2 | aliased plain | `import foo as f` | `f` to a module handle for foo |
| 3 | symbol path | `import foo::MyClass` | `MyClass` to the type `foo::MyClass` |
| 4 | aliased symbol | `import foo::add as my_add` | `my_add` to the function set of `foo::add` |
| 5 | selective | `import foo::{A, b as c, x::Y}` | `A`, `c`, `Y`, each to its target |
| 6 | wildcard | `import foo::*` | every identifier-keyed name in foo's table |
| 7 | anchored | `import self::foo`, `import module::foo` | as (1) to (6), with the path looked for in one directory ([Path resolution](#path-resolution)) |
| 8 | ffi bare | `ffi "c++" import "h.hh"` | see [FFI imports](Interop.md#ffi-imports) |
| 9 | ffi aliased | `ffi "c++" import "h.hh" as my_h` | see [FFI imports](Interop.md#ffi-imports) |

A mixed form (`import foo::{*, A as B}`) is form 5 with a wildcard item and works by composition, and an anchor combines with every native form: `import self::json::{a, b}`, `import module::x as y`, `import self::j::*`. `pub` or `prot` on any form makes it a [re-export](#re-exports).

The anchor is `ImportSpec::kind`, carried to `ImportDecl::import_kind` (`Native`, `SelfRelative`, `ModuleRelative`); the `self`/`module` keyword is never one of `path_segments`, so the bound name, `file_seg_count` and the symbol walk read an anchored path exactly as a plain one. The AST printer and the import-use dump (`"anchor"`) show it.

`import module foo`, with a space, is removed: S089E, with a fix-it deleting `module`, after which the line parses on as plain `import foo`. It forced the directory form, which nothing needs now that `foo.k` beside `foo/module.k` in one place is an error (R005E). `import self` or `import module::` with no path after the `::` is S046E.

The importer never learns which form was used. After phase I all seven are overlay entries keyed by this TU's identifier indices, holding targets.

## Path resolution

The PP walks the import graph (`FileImportIndex`), resolves each path through `ImportResolver` (`Compiler/Resolution/ImportProbe.k`), loads the file and stamps the `ImportDecl`:

| Field | Meaning |
|---|---|
| `ImportDecl::resolved_fid` | the file the path named; 0 when unresolved |
| `ImportDecl::file_seg_count` | how many leading segments named the file, from the segment count the resolver consumed (`ResolveOut::seg_count`); equals the path length for a module import, 0 for an unresolved or ffi import |
| `TranslationUnit::import_edges` | `(fid, decl)` per import, in declaration order |

Phase I never touches the filesystem.

### Search dirs

The current directory and every `-I dir` (and `--macro-search-path dir`) are search dirs with no name. A file under one, and under no [pinned library](#module-pinning), has its path relative to that dir as its module path: `./a.k` is `a`, and `inc/sub/b.k` under `-I inc` is `sub::b`. The folder's own name is never part of the path.

`-I` is also clang's `-I`: the same directory is a header path for C and C++ inputs, ffi headers and `#include "x.k"` (`CompilerInvocation::clang_include_dirs`). `--ffi-include` and `--cxx-include` are clang-only. An `-I` spec containing `=` that is not an existing directory is U007E; the old `-I name=dir` form no longer exists, and when the part before `=` could be a library name the message gives the `module.k` line that would pin it (`CompilerInstance::_add_root`).

A directory given twice (`-I inc -I inc`, an `-I` naming the current directory, a symlink and its target, compared by real path) is one search dir.

A file's module path, and so its identity and C++ namespace, is a function of the search-dir set. Every TU of one build must therefore receive the identical `-I` list: R018E catches two files claiming one path within a run, never two runs that disagree about one file.

### One place per form

Each form looks in exactly one place:

| Form | Place | Resolver entry |
|---|---|---|
| `import foo` | the search roots: the libraries, the unnamed search dirs (the current directory, every `-I`), std and builtin, in the [order below](#resolution-order) | `resolve_module_rel` |
| `import self::foo` | the importing file's own directory | `resolve_module_in(path, file_dir)` |
| `import module::foo` | the importing file's module root: the nearest directory at or above it holding a `module.k`, pinned or not | `resolve_module_in(path, module_dir_at_or_above(file_dir))` |

The module root is the directory `prot` is shared across ([Visibility](#visibility)): `Resolution::SearchRoot::module_dir_at_or_above` is the one walk, and `VisibilityFacts::module_dir_of_path` calls it. A file with no `module.k` above it has no module root, and `import module::foo` there is R069E (with an R069N note saying what is missing) instead of R011E.

The current directory is a search root, so a file in it reaches `./foo.k` as plain `import foo`; a file anywhere else reaches the file beside it only as `import self::foo`. An anchored path is resolved in a transient root over that one directory (`ImportResolver::_sibling_root_for`), never against the search roots, so no file added to a search root changes what it means. Its identity is still `canonical_module_path`'s: a file is one module however it was reached.

`FileImportIndex::_resolve` (the PP) and `DepScanner::_scan_one_import` (the graph) apply the same rule through the same two entry points, so the graph reaches every file the walk resolves.

### Migration

A plain import that every root misses, for every prefix of its path, is retried in the importing file's directory; a hit there resolves (to the file the import always meant) and reports R068E at the first path segment, with a fix-it inserting `self::`. A root answer always wins, so a plain import of a library is never affected by a same-named file beside the importer.

R068 is an error (it was a warning while the tests migrated; `FileImportIndex::_legacy_sibling` now reports `R068E`), but the import still resolves so it does not cascade. Removing the fallback entirely afterwards is the two `_resolve_greedy(..., true, self._dir)` / `_resolve_place(..., true, ...)` calls.

### Files and module.k

In its one place, a path segment `foo` is `foo.k` or `foo/module.k`. Both present is R005E naming the two (`ModuleResolution::file_dir`, `dir_path`); the file answers so the import does not also fail. A `module.k` names its directory, and at a root's top level the directory is the root itself: `Lib/std/module.k` is `kairo::std`, not `kairo::std::module`. A name that consumes a library's whole path resolves to that library's `module.k`, which is how `import builtin` and `import kairo::std` resolve. `module X { }` inside a file appends `X` to the file's path.

A path segment is a file or directory name, spelled as a C++ identifier the same way a file stem is (`CXXSpell::cxx_segment`: `operator.k` is `operator_`). A primitive type's word is a segment like any name (`ImportGrammar::is_import_path_word`): `import self::f8::*` imports `f8.k`, though `f8` lexes as a type keyword. Only where the word would be the BOUND name (`import self::i32`, an item `{u8}` without `as`) is it S046E with a fix-it adding ` as i32_mod`: `i32::f()` names the primitive type, never the module.

### Resolution order

For a plain import, `ImportResolver::resolve_module_rel` tries, in order:

1. the importing file's own root, with the path as written;
2. its own library when no root registered it, with the path as written;
3. libraries whose spelling matches the path's leading segments, longest spelling first;
4. the remaining undiscovered roots, with the path as written.

The importing file's own directory is not on the list (it is `self::`'s place), except as the [migration](#migration) fallback after all four miss.

A file inside a library, registered or found by walking up, never falls back into an unnamed search dir: a library cannot depend on what one build's command line holds.

Longest-first matching is what makes prefix names legal. With `kairo::std` and a hypothetical `kairo` both registered, `import kairo::std::vec` is the former's `vec.k` and never the latter's `std/vec.k`. Only equal names collide.

### Collisions

One module path naming two files is an error, never first-wins:

| Case | Diagnostic |
|---|---|
| two libraries with one name or one spelling | R018E, from the driver before anything is parsed (`ImportResolver::take_root_collisions`) |
| two unnamed search dirs answering one import path with different files (`./a.k` and `inc/a.k` under `-I inc`) | R017E at the import, naming both (`cross_root`). Once one unnamed dir answers, every other is probed, so the importer's own dir winning cannot hide a twin. |
| a pinned directory found walking up that claims a registered library's name, or another such directory's | R018E |
| two inputs from two search dirs with one module path (`kairo a.k inc/a.k -I inc`) | R018E, claimed by the driver before compiling either (`ImportResolver::claim_identity`, keyed by real path; `CompilerInstance::_claim_input_identities`) |

Unnamed search dirs never collide by name: an empty name prefixes nothing.

### The std and builtin roots

The driver registers two named roots (`ImportResolver::Builder::add_include(path, name, spelling)`):

| Root | Name (identity, C++ namespace) | Spelling (what source writes) | Directory | Override |
|---|---|---|---|---|
| std | `kairo::std` | `std` | `<resource-dir>/std` | `--std-dir`; `--no-stdlib` skips it |
| builtin | `builtin` | `builtin` | `<resource-dir>/builtin` | `--builtins-dir` |

`SearchRoot::name` is the root's identity: `Lib/std/io.k` is `kairo::std::io` and emits into `::kairo::std`, which cannot collide with C++'s `std`. `SearchRoot::spelling` is what `resolve_module_rel` matches; `canonical_module_path` reads only the name, so the spelling never reaches an emitted namespace. Every other root's spelling is its name.

There is no std prelude. `import std::io` binds `io`, `import std` binds `std` (the root's `module.k`), and a bare `std` in a file that did neither is an ordinary unresolved name. The PP does not add std to the graph either; an import of it does. C++'s `std` is reached as [`cxx::std`](Interop.md#ffi-imports).

builtin is the one prelude: every non-builtin TU receives a synthesized `ImportDecl` with `is_prelude = true` and `resolved_fid` stamped directly (`FrontendAction::_sema`), which phase I folds like any wildcard import. `Lib/builtin/module.k`'s `pub import`s re-export through the ordinary path. `--print-imports` labels the prelude `<prelude>`; the AST printer hides it.

## Import resolution

Phase I, `Compiler/Sema/Resolve/ImportResolution.k`. For each `ImportDecl` it folds the source TU's frozen symbol table into this TU's `ImportOverlay` (`Compiler/AST/Context/ImportOverlay.k`), keyed by this TU's identifier indices: each name is spelled once and re-interned once. Targets are references into the source TU's arena; nothing is copied.

After I the TU is self-contained: unqualified lookup is DeclContext chain, then overlay, then miss. Later phases only read other TUs (frozen tables, canonical type slots, an imported generic's typed body). The only cross-TU writes go to the two locked build-wide structures, the canonical type store and the instantiation registry ([invariants](Pipeline.md#invariants)).

Import cycles are legal: the files of a cycle run I as one group in lockstep, and the group's re-exports are refolded to a fixpoint after I ([Pipeline.md](Pipeline.md#compilation-phases)); cycle reporting (R058W) is the preprocessor's ([Lexing.md](Lexing.md#preprocessor)).

### What phase I reads

Index mode hoists declaration heads into the `DisambigTable` so the parser can disambiguate `<`. Imported generics are found lazily through `import_edges` (`GlobalDisambigTable::lookup_in`), never merged into the importer's table. The full parse freezes one `SymbolTable` per declaration-owning scope (`ASTParse::_build_symbols`), and `ASTParse::_synthesize_module_self` gives every non-root file a `ModuleDecl` that shares the TU's table, so a plain import has a real `*Decl` to bind. Nothing before I reads another TU's AST.

### Symbol paths

Forms 3 and 4, and multi-segment items of form 5. When `0 < file_seg_count < path_segments.size()`, `_resolve_one` hands the import to `_fold_symbol_path`, which walks `path_segments[file_seg_count..]` with `_walk_segment`: `lookup_foreign` in the source table for the first segment, then the named declaration's own table (through its redeclaration canonical) for each following one. `_fold_selective` routes every item through the same walker, so a single-segment item is a walk of one step. The final cell folds under the alias, or under the last spelling.

| Failure | Diagnostic |
|---|---|
| missing intermediate or final segment | R015E, here and nowhere else |
| a type alias as an intermediate segment | R015E "cannot import through a type alias": alias expansion is T's, and T has not run for this TU |

A module named through a symbol path folds as a module handle, not a type, so `import u1::util` beside `import u2::util` gets the [reopened-namespace](#reopened-namespaces) exemption like two plain imports.

### Prelude handles

`ImportResolution::_add` never lets a prelude module handle and a real import share a key: a real import evicts a prelude handle of the same name, and a prelude handle never lands on a name a real import bound. Two handles under one key would otherwise union into a multi-scope module and `is_ambiguous()` would never fire. The builtin wildcard folds types and function sets, not handles, so the rule does not fire today. A user import colliding with a builtin name is R016E.

## Overlays and visibility

### Overlay entries

An `OverlayEntry` holds the targets folded under one key and a `merged` cell that lookup reads.

| Target kind | Into `merged` |
|---|---|
| `Type` | its declaration |
| `ModuleHandle` (a Kairo module, or a header's under an ffi alias) | its declaration: a name denoting a scope is a lookup answer |
| `FunctionSet` | its cell, unioned with the other function sets (overloads across imports) |

`OverlayEntry::non_function_count` decides ambiguity. It skips module handles and counts distinct entities, not targets, so `import foo::MyClass` beside `import foo::*` is one entity. Two distinct non-function entities under one key are R016E at the import, with one R016N note per candidate. The error is contained: every use of the name is poisoned where it is looked up (`MemberLookup::report_use_ambiguity`), so the TU's signatures still resolve. A collision among header entities only is reported lazily, at the use ([FFI imports](Interop.md#ffi-imports)). A header entity colliding with a prelude entity is designed to defer to the use the same way; today it is R016E at the import.

### Visibility

Phase I records an access fact (`vis`) per target, and N reads it:

- A module handle records `Public`. The import edge's own `pub`/`prot` is a separate question, answered from the target's `origin` ([re-exports](#re-exports)).
- A folded declaration records its own visibility; one that writes none records what its file's default makes it (`ImportResolution::_cell_vis`, `AST/VisibilityFacts.k`): `Private`, or `Protected` when a `module.k` is above the file; `Public` under the old rule (`-fdefault-visibility=pub`, and builtin and std, which keep it until marked).
- N reports R047E when no target of a name reached through the overlay is visible: a private one never is, a protected one only from a file of the same module (`NameResolution::_overlay_access_ok`). The report says why, notes the declaration, offers `pub`, and chains SC272W when a `prot` failed for want of a `module.k`.
- The same rule for a declaration reached through a module handle (`geo::area`) or a bare type name is AccessCheck's ([SemanticChecks.md](SemanticChecks.md#accesscheck)).

A file's module is the directory tree under the nearest `module.k` at or above it, pinned or not (`VisibilityFacts::module_dir_of_path`); the driver stamps every TU's module directory before Sema (`FrontendAction::_sema`), since parallel Sema reads another TU's from any worker.

### Reopened namespaces

A cell whose candidates are all `ModuleDecl`s is one module with several scopes. ChainBinding turns it into a `Module` anchor whose `Anchor.scopes` lists every scope, and a `::` step searches all of them and unions the hits; a genuine ambiguity among the hits is still `_commit`'s to report. TypeResolve's qualified walk applies the same rule in type position (the `mods` list), so `std::vector<i32>` finds `vector` in whichever of libc++'s `std` openings declared it.

Within one TU, `module Util { }` written twice is one entity with several scopes, linked as a redeclaration ring by N:

- Every module block is a definition, and N's two-definitions check skips modules (`_reopenable`). A type member declared in two blocks is judged as one cell (`_judge_reopenings`): a forward declaration in one block chains to a definition in another; two definitions are R029E, two record keywords R063E.
- `NameLookup::unqualified`, on a miss in a module scope, tries every other block of the ring (`module_scopes`), in both directions: the blocks behave as one block with no declaration-order rule.
- N binds `Util` to the ring's canonical, so ChainBinding's single-decl anchor and T's `mods` walk both expand it to `module_scopes(d)`.

Two files that each write `module Util` form two rings. A module reopened in two files can define one signature twice, and nothing diagnoses it before the link (a duplicate-symbol error naming the mangled name). The check belongs at the cross-TU sync point where every TU's declarations are visible; it is not implemented.

A C++ namespace is one ring across headers: `ForeignRegistry::link_namespace` links every header's `ModuleDecl` for one qualified namespace as it mints them, because C++ has one `std` however many headers reopen it. Each header keeps its own table; argument-dependent lookup walks the ring (`MemberLookup::_enclosing_modules`).

### Cross-TU probes

A foreign module's table is probed by spelling, never by this TU's identifier index: `MemberLookup::in_scope` re-interns the name per scope, and `NameLookup::ctx_of` answers which context a declaration's names live in for dumps and diagnostics. Two TUs' interners agree on an index only by accident.

### Import-use dump

`--dump-import-uses=<path.json>` writes, after Sema, every TU's written imports and each name the overlay answered, attributed to the import(s) whose targets hold it (`OverlayTarget::origin`), with the spelled use sites (`FrontendAction::_dump_import_uses`). The overlay is the one place an import answers a name, so `NameLookup::unqualified` logs each overlay hit into `ImportOverlay::uses` (an `ImportUseLog`, allocated by I only under the flag; one null check otherwise). The site is `NameLookup::use_at`, set around the lookup by the callers that hold a token (N's identifier and out-of-line qualifier heads, an `extend` target, T's type heads); a hit with no site (lang items, operator fallbacks, attributes) is counted as `implicit`, and one outside the TU's file (a macro body, an imported node T read) as `foreign`. An import used only for the `extend` blocks of its file is a real use: extensions are visible through the import DAG (MemberLookup.md#visibility), not through the overlay, so the log records no name for it.

`Scripts/import_lint.py` reads the dumps (one per configuration and entry, unioned) and reports or rewrites wildcard, dead and misordered imports; its docstring has the rules.

## Re-exports

A `pub` or `prot` import is part of its file's surface. A re-exported name lives in the source TU's overlay, never in its symbol table, while a plain `import foo` binds foo's `ModuleDecl`, whose table is that symbol table. The two ways of reaching a re-export therefore need two mechanisms:

| Importer writes | Mechanism |
|---|---|
| `import foo::*` | `_fold_reexports` folds the source overlay's re-exported targets into this overlay, each with its own kind, `vis`, cell or declaration and source fid. DAG order guarantees the source overlay is complete and already transitively closed. |
| `import foo::{...}` | folds no re-exports; a selective import names exactly what it takes |
| `import foo`, then `foo::name` | ChainBinding's module step consults the source overlay after missing in the table (`MemberLookup::reexport_lookup`, name re-interned into the source TU's index space, probe-only) |

Both (and the symbol-path walk, `_reexported_cell`) accept a target only when its `origin` import re-exports to the importer (`VisibilityFacts::reexports_to`): it is `pub`, or it is `prot` and the importer is a file of the source's module. A private import edge in the source is never surface. A folded re-export takes this TU's import as its `origin`, so it is surface here only if that edge is `pub`/`prot` too. Keeping the source's origin instead leaked every target that once crossed a `pub import` through private edges and grew one duplicate per import path.

A form re-exports what it bound. `pub import bar` re-exports the name `bar`, so an importer of foo writes `foo::bar::f()`; `pub import bar::*` re-exports bar's contents, so it writes `foo::f()`.

A re-export also carries the `extend` blocks of its target onward, whatever its form ([MemberLookup.md](MemberLookup.md#visibility)): a file sees the extensions of the files it imports and of what those re-export, and a private edge further down carries none. A `prot` edge carries them only to an importer in the module of the file that wrote it, the same rule (`reexports_to`) the name overlay applies.

## Module pinning

A library is named by a declaration in its `module.k`, never by its folder or by the command line. The design follows from one requirement: a file's module path, and so its C++ namespace and symbol names, is a property of the file. `kcc -c lib/y.k` and a run that reaches `y.k` through an import must agree on `y`'s symbols, or separately compiled objects do not link ([kcc](Interop.md#kcc)).

### The pin

A `module.k` whose first declaration is the bare `module a::b` (a module path ended by a newline or `;`) makes its directory the root of library `a::b`. `geometry/module.k` saying `module geo` is imported as `geo`, and `geometry/inner/x.k` is `geo::inner::x`. A name may have several segments: `Lib/std/module.k` pins `kairo::std`.

The resolver reads a pin with `read_module_pin` (`Compiler/Resolution/SearchRoot.k`): a byte scan of the file's first declaration, no lex, cached per directory (`_dir_pins`).

### Placement

The parser accepts the bare form in any file and records it on `TranslationUnit::pin_segments`. `ModulePinCheck` (`Compiler/Sema/Verify/ModulePinCheck.k`, a Verify pass) enforces where it may stand, all as R064E:

| Rule | Function |
|---|---|
| only a file named `module.k` may carry a pin; elsewhere the error points at the block form `module foo { ... }` | `pin_allowed` |
| the pin must be the file's first declaration, the one the resolver reads; checked by running the resolver's own scanner over the file | `pin_counts` |
| a second pin | `run` |

The module.k-only rule is one predicate by design. Two other meanings for a pin outside `module.k` were considered and left open: naming the file itself (`utils/strings.k` saying `module text` is `utils::text`), or wrapping the rest of the file (`module foo { <rest> }`). Adopting either changes `pin_allowed` and its diagnostic, never the parser or the resolver.

### Finding a file's library

`ImportResolver::canonical_module_path` (`_library_of`) walks up from the file's directory to the nearest directory that is a named root or whose `module.k` pins a name, past the current directory and past any `-I` dir holding the file, bounded by the filesystem root, with one cached stat per directory and never downward. That name prefixes the path. So `cd geometry/inner && kairo x.k`, `-I geometry/inner`, `kairo /abs/.../geometry/inner/x.k` and an importer above the library all give `geo::inner::x`. Only a file with no library above it takes its path relative to the deepest search dir holding it.

### Registration

Libraries are registered in each search dir itself (an `-I` dir whose own `module.k` pins is that library) and in its immediate subdirectories: one `readdir` per root and one small read per `module.k`, never a recursive walk (`ImportResolver::build_index`). A pin registers a library root (`SearchRoot::discovered`) reachable by its name only: `-I libfoo` over `module foo` does not make `libfoo/x.k` importable as `x` as well as `foo::x`.

A pinned directory deeper than that, or above every root, is not registered and cannot be imported by name from outside it. Its own files resolve their imports against it, with the path as written and by its name as a leading segment (`_pinned_root_for`, a transient root), so `geometry/inner/x.k` writing `import geo::shapes` or `import shapes` resolves however `x.k` was reached.

The driver's `builtin` and `kairo::std` registrations are the only names given outside a pin (std's spelling `std` cannot be written as a pin). `build_index` checks that each agrees with its directory's own pin; a disagreement is R059E. An `-I` naming std's or builtin's directory is folded into the driver's registration, in the `-I`'s search position.

### Inputs are modules

A `.k` on the command line, or one a C++ input includes, takes the module path an import of it would get (`ImportResolver::input_module_path`). `lib/y.k` compiled from the current directory is `lib::y` whether it is compiled, imported or included, and its `priv` declarations keep external linkage.

A pathless TU keeps the entry rules (`CXXSpell::is_entry_tu`): namespace is the file stem, `priv`/`internal` declarations go in an unnamed namespace nested in it, and no header is emitted ([Codegen](Codegen.md#cxxspell)). A TU is pathless when it is outside every search dir and every library, when its path under an unnamed dir starts with a named root's name (`./builtin.k` would claim the builtin library's path), when it is the driver's virtual library entry, or when it is a `module.k` at the top of an unnamed, unpinned dir.

`main` declared at file scope in any TU is the program's global `int main` (`CXXSpell::is_main`); one inside a `module foo { }` block is `foo::main`.

The driver's `_kairo_order` (importers before the inputs they import) no longer decides identity; it remains only because the importer still claims the file it reaches first, and its fid-0 placeholder is still needed.

### Consequences

- A file's path is fixed by its root. `~/foo/b.k` writing `import a`, under a `~/foo/module.k` pinning `foo`, resolves to `~/foo/a.k`, which is `foo::a` from every importer.
- Reopening never crosses a root. `module a { }` in a current-directory file reopens `a`, never `foo::a`.
- Nothing outside the source tree reaches the ABI ([invariants](Pipeline.md#invariants)).

### Decisions

| Id | Question | Decision |
|---|---|---|
| A | a bare `module foo` outside `module.k` | an error for now, behind the single predicate `pin_allowed` |
| B | `-I name=dir` | removed; `-I dir` is both a Kairo search dir and a clang `-I` |
| C | the entry file | every input is a module; `main` is global wherever declared |
| D | std's name | `Lib/std/module.k` pins `kairo::std`; the driver keeps the spelling `std` |
| E | one module path from two search dirs | an error (R017E at an import, R018E for inputs) |
