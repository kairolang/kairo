# Imports: the full contract

Design spec for how a name written in one file comes to refer to a
declaration in another, and how that reference survives lowering to C++.
Companion to RESOLUTION.md (§2 "I ImportResolution" is the lookup half of
this document; §2b is member lookup). Where the two disagree, this one is
newer and wins.

Status legend used throughout:

    [DONE]     implemented and tested against a dump
    [BROKEN]   implemented, produces the wrong result; fix is specified below
    [MISSING]  not implemented; owner and shape are specified below
    [DECIDED]  a rule with no code behind it yet; do not relitigate

---

## 0. The one-sentence model

**Imports are erased at name resolution.** After N and ChainBinding, every
use site holds a `*Decl`; the decl knows its own home through the
DeclContext parent chain; nothing after sema reads an `ImportDecl`. Codegen
regenerates, per TU, the declarations a C++ header would have provided,
derived from those `*Decl` links. The only `#include` in emitted C++ is an
`ffi` import.

Everything below is a consequence of that sentence.

---

## 1. The seven forms

Grammar: `Parser/Shared/ImportGrammar.k` (one grammar, three drivers: parser,
PP, dep-scanner). All seven parse today. What each one MEANS, and what it
becomes after phase I:

| # | Form | Example | Binds in the overlay |
|---|------|---------|----------------------|
| 1 | plain | `import foo` | `foo` -> ModuleHandle(foo's ModuleDecl) |
| 2 | aliased plain | `import foo as f` | `f` -> ModuleHandle(foo) |
| 3 | symbol path | `import foo::MyClass` | `MyClass` -> Type(foo::MyClass) |
| 4 | aliased symbol | `import foo::add as my_add` | `my_add` -> FunctionSet(foo::add cell) |
| 5 | selective | `import foo::{A, b as c, x::Y}` | `A`, `c`, `Y` -> each target |
| 6 | wildcard | `import foo::*` | every ident-keyed name in foo's table |
| 7 | module-only | `import module foo` | as (1), but resolves `foo/module.k` only, never `foo.k` |

Plus the two ffi forms, which are imports of *headers*, not of Kairo files:

| # | Form | Binds |
|---|------|-------|
| 8 | ffi bare | `ffi "c++" import "h.hh"` | every ident-keyed name of every header in h.hh's include closure |
| 9 | ffi aliased | `ffi "c++" import "h.hh" as my_h` | `my_h` -> one ModuleHandle per closure header (each header TU's module_self) |

Mixed forms (`import foo::{*, A as B}`) are (5) with a wildcard item, and
work by composition. `pub`/`prot` on any form is re-export (§4.4).

**The importer never learns which form was used.** By N, all seven look
identical: an overlay entry keyed by this TU's imm, holding targets.

---

## 2. Pipeline: what happens at each stage

    PP     resolve import PATHS to fids; stamp the node       [DONE]
    Index  hoist decl heads for parser disambiguation         [DONE]
    Parse  build AST; freeze per-DC symbol tables             [DONE]
    I      ImportResolution: build this TU's overlay          [DONE]
    N      NameResolution: bind heads through the overlay     [DONE]
    T      TypeResolution: canonicalize types                 [DONE]
    CB     ChainBinding: bind `::` and `.` steps              [DONE]
    ...
    EP     EmitPlan: plan the per-TU C++ interface            [DONE]
           EmitPlan: EMIT it                                 [MISSING]
    CG     TokenSink: emit                                    [needs one rule]

### 2.1 PP path resolution

`Preprocessor/FileImportIndex.k` walks the import graph, resolves each path
through `ImportResolver` (file-first: `foo.k`, fallback `foo/module.k`;
`import module` is fallback-only), loads the file, and stamps
`ImportDecl::resolved_fid`. It also records `TranslationUnit::import_edges`
(fid, decl) in declaration order. **The PP is the one writer of path->file.**
Phase I never touches the filesystem.

[DONE] `import foo::MyClass`. The PP now stamps

    ImportDecl::file_seg_count: u32   // leading segments that named the FILE

next to `resolved_fid`, from the segment count `ImportResolver` actually
consumed (`ResolveOut::seg_count` = the `try_len` that resolved), not
guessed from the path string. `== path_segments.size()` for a plain module
import, `0` for unresolved or ffi. See §4.1.

[DONE] **Module roots and paths.**

A module path is `[root name] + directories + file`, and every part of
that is fixed by where the file sits, never by who imports it.

- **Every root has a name, and the name is a module PATH.** `-I ~/foo`
  registers a root named `foo` (the directory basename; `-I name=path`
  overrides, and the name is split on `::`). `import foo::a` resolves to
  `~/foo/a.k`, whose module path is `foo::a`. A name may have several
  segments: Kairo's own standard library registers as `kairo::std`, so
  `Lib/std/vec.k` is `kairo::std::vec`. `module.k` names its directory --
  and at a root's TOP level the directory IS the root, so `Lib/std/module.k`
  is `kairo::std`, not `kairo::std::module`. `module X { }` inside a file
  appends `X`.
- **Root names match longest first.** An import path is matched against
  each root's segment list on its LEADING segments, longest name winning:
  with roots `kairo::std` and a hypothetical `kairo`, `import kairo::std::vec`
  is the former's `vec.k` and never the latter's `std/vec.k`. Longest-first
  is what makes prefix pairs legal; only EQUAL names are the collision
  below. A name that consumes the whole path names the root itself and
  resolves to its own `module.k` -- that is how `import builtin` and
  `import kairo::std` resolve.
- **The entry root is unnamed.** The directory of the entry file is a
  root with no name, so `./a.k` is `a`. It is the only unnamed root, and
  therefore the only root whose files are importable with a bare first
  segment. The entry TU itself has no path (`module_self` null) and emits
  into the global namespace; every non-`main` decl in it gets internal
  linkage (unnamed C++ namespace), because no path can reach the entry TU
  and nothing outside it will ever link against it.
- **A file's path is fixed by its root.** `~/foo/b.k` writing `import a`
  resolves inside its own root to `~/foo/a.k`, and that file is still
  `foo::a` same file, same path, same C++ namespace from every
  importer. This is what invariant #9 requires and why root names cannot
  be optional.
- **Resolution order for an import path:** the importing file's own root
  first, then named roots matched by leading segment. Library roots
  never see the entry root: it is a leaf of the import graph.
- **Two roots with the same name is a build error** from the
  ImportResolver, before anything is parsed. Never first-wins, never a
  merge.
- **Reopening never crosses a root.** Two files under the same root
  producing the same path are one module (§4.3). `module a { }` in an
  entry-root file reopens `a`, never `foo::a`.
- **One module is one C++ namespace and obeys C++'s definition rules,
  checked by Kairo.** Across every reopening of a module: a forward
  declaration plus one definition of a signature is a redecl chain; two
  definitions of the same signature is a redefinition error at the
  second, noted at the first. This needs signatures (T) and every
  reopening (cross-TU), so it lives at the M2 sync point. Until then the
  use site still errors (an identical-signature candidate pair is
  ambiguous at overload resolution); the definition site does not.

Mechanically: `ImportResolver::Builder::add_include(path, name)`;
`SearchRoot::name` carries it (empty = the entry root);
`canonical_module_path` prefixes it, so `module_base` for a file under a
root is `[root name] + relative directories`. `-I path` takes the
directory's basename; `-I name=path` overrides it, split on the first
`=`. `resolve_module_rel` probes the importing file's OWN root with the
path as written, then any root whose name is the leading segment with
the rest of the path, then the remaining roots except that a file
under a named root never falls back into the entry root, which is a leaf
of the import graph. Two roots claiming one name is an R018E from the
driver before anything is parsed (`take_root_collisions`).

**The std root.** `Lib/std` is a named root whose name is the two-segment
path `kairo::std` (`<resource-dir>/std`; `--std-dir` overrides, `--no-stdlib`
skips it). Two segments so that its decls emit into `::kairo::std`, which can
never collide with C++'s `std`, and so that the bare name `std` is free to
mean something else. It means a TU-LOCAL ALIAS: every non-builtin, non-std TU
receives a synthesized `import kairo::std as std` with `is_prelude = true` and
`resolved_fid` stamped to `Lib/std/module.k`, folded by I through `_fold_plain`
like any other aliased plain import. `--no-stdlib` or `--no-prelude` suppresses
it; `--print-imports` labels it `<prelude>`; the AST printer hides it.

A graph edge and a name binding are two different things, so BOTH halves
exist: the PP adds `kairo::std` to the import graph next to `builtin` (without
it the tree is never loaded and there is no fid to stamp), and the driver
synthesizes the ImportDecl once sema has a TU to hang it on. `PPResult::std_fid`
carries the fid between them, and the std subtree is marked
(`GlobalDisambigTable::mark_std_fid`) rather than tested on the module path,
because the segments are PreprocessorSymbolTable ids no Sema pass can reach.
builtin files are skipped too: builtin DECLARES what std extends, so std
imports builtin and never the reverse.

**Shadowing the alias.** Bare `std` is an ordinary overlay binding, so a TU's
own `module std { }` shadows it by the ordinary rule (DC chain before
overlay), with no special case. A real IMPORT of the same name is not
ordinary, and this is the one place the prelude is not: two `ModuleHandle`
targets under one key UNION into a multi-scope module -- `non_function_count`
exempts ModuleHandle so reopened namespaces and ffi closures work (§4.3) --
so a user's `import std` would silently merge their namespace with
`kairo::std` and `is_ambiguous()` would never fire. Rule: a real import
EVICTS a prelude handle of the same name, and a prelude handle never lands on
a name a real import already bound (`ImportResolution::_add`). Handles only:
builtin's wildcard folds Type and FunctionSet targets, and a user import
colliding with one of those is still the R016E it always was.

**The builtin root.** `Lib/builtin` is a named root (`builtin`) the
compiler always registers (`<resource-dir>/builtin`; `--builtins-dir`
overrides). Every non-builtin TU receives one synthesized `ImportDecl` with
`is_prelude = true`, `resolved_fid` stamped directly (no path to resolve),
folded by I like any wildcard import; `module.k`'s `pub import`s re-export
through the ordinary path. `--print-imports` labels it `<prelude>`; the AST
printer hides it. A one-segment import of a named root (`import builtin`)
resolves to the root itself (ImportProbe no longer requires two segments).

### 2.2 Index + Parse

Index mode hoists decl heads into `DisambigTable` so the parser can
disambiguate `<`. Imported generics are found lazily through
`import_edges` (`GlobalDisambigTable::lookup_in`), never merged.
Full parse builds the AST and `ASTParse::_build_symbols` freezes one
`SymbolTable` per decl-owning scope. `_synthesize_module_self` gives every
non-root file a real `ModuleDecl` that *shares* the TU's table, so a plain
import has a genuine `*Decl` to bind.

Nothing here reads another TU's AST.

### 2.3 I ImportResolution

`Sema/Resolve/ImportResolution.k`. For each `ImportDecl`, fold the source
TU's **frozen symbol table** into this TU's `ImportOverlay`, keyed by THIS
TU's imms (spell once, re-intern once hard invariant #2). Targets are thin
references into the source arena; nothing is copied.

After I the TU is self-contained: unqualified lookup is
`DC chain -> overlay -> miss`, and no later phase touches another TU until
the M2 sync point. Cross-TU *reads* of frozen tables and canonical type
slots are fine; that is what DAG order guarantees.

**Ordering.** `CompilerInstance::_sema` runs the pipeline per fid in
reverse tree order = import-DAG order. Load-bearing for I (source overlay
complete before an importer folds re-exports) and for T (imported file's
type nodes canonical before an importer expands an alias through them).
Do not change that loop order.

[DONE] The three defects in I, and re-export:

1. `_rebuild_merged` admits `ModuleHandle` targets (a Kairo module, or a
   C++ header's under an ffi alias). A name denoting a scope is a
   legitimate lookup answer; excluding them made `foo` after `import foo`
   resolve to an EMPTY cell.
2. `OverlayEntry::non_function_count` exempts that kind, and counts
   DISTINCT entities rather than targets so `import foo::MyClass`
   alongside `import foo::*` is not an ambiguity either.
3. Symbol-path imports fold through `_fold_symbol_path`. See §4.1.
4. Re-export is folded. See §4.4.

A module handle records `Public` as its ACCESS fact. `vis` is
what N reads to say "exists but is private"; recording the import edge's
own pub/prot there made every plain `import foo` report "'foo' is
imported but is declared private in its module". Whether the edge
re-exports is a separate question, answered from `origin` in §4.4.

### 2.4 N NameResolution

Binds every *head*: unqualified idents, params, locals, binders, pattern
binders, out-of-line qualifiers, attribute names. Lookup order is locals ->
DC chain -> overlay. A private-decl name reached ONLY through the overlay is
the "exists but is private" error, emitted here from the visibility fact I
recorded. Protected is not enforced (needs member-lookup provenance).

N hands every chain step through untouched. [DONE]

### 2.5 T TypeResolution

Canonicalizes every type node. Expands aliases on demand across TUs (safe
under DAG order). Imports are invisible here: `var m: MyClass` resolves
`MyClass` through the overlay exactly like a local name. [DONE]

### 2.6 CB ChainBinding

Binds `::` and `.`/`->`/`?.` steps from what the previous step denotes:
module table, type members (own + extensions + base DAG, merge-not-hide),
or a value's declared type's members. Aliases are transparent: `f::add`
after `import foo as f` steps into foo's shared table because `f` is bound
to foo's `ModuleDecl`. [DONE]

[DONE] Reopened namespaces. An all-`ModuleDecl` candidate set is a
`Module` anchor with N scopes (`Anchor.scopes`); `::` steps search every
one and union the hits; a genuine ambiguity is still `_commit`'s to
diagnose.

[DONE] No ffi special case. An ffi alias binds the header TUs' own
ModuleDecls, so a step off it is an ordinary multi-scope `Module` step
into tables Sema/Foreign filled. See §5.

[DONE] Cross-TU probes are spelled, not imm-keyed. `in_context` probed a
foreign module's table with THIS TU's imm index, which is right only when
the two interners happen to agree (`bar::id` resolved, `bar::Box` did
not); the record walk had the same fault, so a member of an imported type
never resolved. `MemberLookup::in_scope` re-interns per scope. Rendering
a foreign decl is the same problem: `NameLookup::ctx_of` answers where a
decl's names live, and the dump and diagnostics ask it first.

### 2.7 EP EmitPlan [DONE]

The codegen half; CODEGEN.md is the full description. InterfaceEmitter
emits every declaration into either sink; EmitIR emits bodies for the
C++-shaped core, method and extension-member definitions, and template
member bodies into home TUs; explicit instantiation definitions follow
every body. One object per non-foreign TU.

---

## 3. Invariants (add to RESOLUTION.md §3)

8. **Imports are erased.** No pass after N/CB reads an `ImportDecl`. A
   codegen decision that needs "how was this imported" is a bug; ask the
   decl where it lives (`is_imported()` for a C++ header's).
9. **One namespace per decl, derived, never stored per use.** A decl's C++
   namespace is its DC parent chain -> `ModuleDecl::module_path`. Every TU
   that emits that decl computes the same path from the same node.
9a. **Nothing outside the source tree reaches the ABI.** A decl's C++
    namespace is a function of its root's declared name and its path
    within that root, plus any `module X { }` blocks enclosing it — and of
    nothing else: not the checkout's directory name, not a flag, not the
    importer's spelling. Two builds of one tree emit byte-identical
    interfaces. The entry TU has no path and emits into the unnamed
    namespace, `main` excepted.
9b. **Compiler-invented names come from one file.** `AST/LangItems.k` holds
    both kinds: LANG ITEMS (a decl a user could have written, arriving
    through ordinary imports, filled once per build on the
    GlobalDisambigTable) and LOWER TARGETS (a fragment of a C++ name that
    no Kairo declaration spells -- `__kairo_contains` for `op in`,
    `__kairo_pow` for `op ^^`). Nothing else in the compiler carries a copy
    of any of those strings, and `CxxNameCheck` rejects a user identifier
    that starts with the reserved prefix, so an invented name can never
    collide with a written one.
10. **Aliases are TU-local.** An alias never appears in an exported
    interface. C++ consumers see canonical names only.
11. **Class granularity.** A class enters a TU's emitted interface whole
    (every member declared) or not at all. Never a subset.
12. **Bodies are out-of-line, home TU only.** A class body contains no
    function bodies anywhere, including in its home TU. This is what makes
    the class definition byte-identical across TUs (C++ ODR).
13. **Clang never instantiates.** Every generic instantiation is
    enumerated by Kairo sema, checked by Kairo sema, and emitted explicitly.
    Emitted templates carry no `requires`.

---

## 4. Lookup-side work items (sema)

### 4.1 Symbol-path imports [DONE]

Forms 3 and 4, and multi-segment items in form 5.

In `_resolve_one`, before the wildcard/items dispatch:

    if file_seg_count > 0 && file_seg_count < path_segments.size():
        _fold_symbol_path(id, overlay, src_tu, src_syms, src_imms, fid)
        return

`_fold_symbol_path` walks `path_segments[file_seg_count..]`:
`lookup_foreign(src_syms, src_imms, spelling)` for the first, then
`context_of(decl)->dc_symbols` per following segment (through the redecl
canonical; aliases are NOT expanded here an alias as an intermediate
segment is an error at I, "cannot import through a type alias", because
expansion is T's and T has not run for this TU). The final cell folds via
`_fold_cell` under `alias` or the last spelling. `_fold_selective` must
route items with `sub_path.size() > 1` through the same walker; today it
reads only the last token and looks it up at top level.

Error homes: missing intermediate or final segment -> `R015E` here, nowhere
else. `_walk_segment` is the one walker; `_fold_symbol_path` and
`_fold_selective` both go through it, so a single-segment item is that walk
with one step.

A module named through a symbol path folds as a `ModuleHandle`, not a
`Type`, so §4.3's exemption covers `import u1::util` / `import u2::util`
as well as two plain imports.

### 4.2 Module handles in `merged` [DONE]

`_rebuild_merged`: append `t.decl` for `Type` and `ModuleHandle` targets.
Only `FunctionSet` unions cells.

### 4.3 Reopened namespaces [DONE]

`non_function_count`: skip `ModuleHandle`. The same exemption makes an ffi
alias over N closure headers one scope, not N ambiguous entities.
TypeResolve's qualified walk applies the rule in TYPE position too (`mods`):
while a segment's cell is all modules, the next `::` segment is looked up in
every one of them, so `std::vector<i32>` finds `vector` whichever of libc++'s
many `std` openings declared it.
ChainBinding: `Anchor.scopes: vec<*DeclContext>`; all-module candidate
sets become a multi-scope `Module` anchor; `::` searches every scope.

Same TU, `module Util { }` written twice: one entity, N scopes, linked as a
redecl ring by N(a). Three rules make the ring behave as one block:
- **Not a redefinition.** Every module block is a definition; N(a)'s
  two-definitions check skips modules (`_reopenable`). Two reopenings
  declaring the same MEMBER twice is item 13a's question, at M2.
- **Unqualified sees the ring.** `NameLookup::unqualified`, on a miss in a
  module scope, tries every other block of its ring (`module_scopes`), so
  `a` declared in block 1 is in scope in block 2 -- and block 2's names in
  block 1: no declaration-order rule, "as if one block".
- **A collapsed decl expands.** N binds `Util` to the ring's canonical as a
  single decl, so ChainBinding's single-decl Module anchor and T's `mods`
  walk both push `module_scopes(d)` (deduped), not `context_of(d)`.
  `tests: Tests/Sema/lookup_module_reopen.k`.
Two FILES both writing `module Util` are two rings; merging those is the
cross-reopening question at M2 (item 13a).

### 4.4 Re-export [DONE]

RESOLUTION.md §2 already decides the rule: a `pub`/`prot` import is
surface. A re-exported name lives in the source TU's OVERLAY, never in its
symbol table, and a plain `import foo` binds foo's ModuleDecl whose shared
table IS that symbol table so the two ways of reaching a re-export need
two mechanisms:

- A **wildcard** import folds the source's re-exported targets into this
  TU's overlay (`_fold_reexports`), carrying each target's own kind, vis,
  cell/decl and src_fid. DAG order guarantees the source overlay is
  complete, and already transitively closed. A **selective** import names
  exactly what it takes, so it folds none.
- A **plain** import reaches them through `foo::name`, so ChainBinding's
  module step consults the source overlay after missing in the table
  (`MemberLookup::reexport_lookup`, name re-interned into the source TU's
  imm space, probe-only, never interning).

Both paths accept a target only when its `origin` import is pub/prot, so
wall 1 holds: a `priv` import edge in the source is never surface.

Note what a form re-exports. `pub import bar` re-exports the NAME `bar`,
so an importer of foo writes `foo::bar::f()`. `pub import bar::*`
re-exports bar's contents, so it writes `foo::f()`. The overlay records
what the import bound, and re-export hands exactly that on.

### 4.5 Protected-import enforcement [MISSING]

Needs member-lookup provenance (same library?). Home: `AccessCheck.k`,
after ChainBinding. Not an import problem; listed for completeness.

---

## 5. ffi imports

[DONE] An ffi import imports real declarations. Clang parses the header;
Sema/Foreign translates what it declares into ordinary Kairo decls, one TU
per header; phase I folds them exactly as it folds a Kairo file. No pass
after I asks where a decl came from except through `FFILinkage`
(`is_imported()`, the C++ spellings, layout, `ffi_c_variadic`,
`ffi_explicit`, `clang_decl`).

    PP       PPWalker::_handle_ffi builds the ImportDecl (header, alias,
             linkage) and appends the unquoted spelling to the file's
             ORDERED header list; _finalize requests one HeaderSet for the
             list (HeaderSetCache::request). The clang parse runs on the
             pool (HEADER_BUILD_GROUP), overlapping the Kairo parse.
    driver   FrontendAction::_sema, before any sema: wait_all; per fid with
             a set, HeaderIndex::index (a fid + TU per header clang touched,
             in touch order; DeclImport declare then define; freeze), then
             _attach_ffi_edges: closure_of(spelling) -> resolved_fid (the
             header's own fid), ffi_closure_fids (its transitive include
             closure), one ImportEdge per closure header.
    I        _resolve_ffi. Aliased: one ModuleHandle per closure header, all
             under the ONE alias key -- the reopened-namespace shape (§4.3),
             so `my_h::f` searches every header's table. Bare:
             _fold_all_cells over every closure header, as the `#include`
             it stands for would, MINUS the name `std` (see below).

**`cxx::std` is C++'s `std`.** Bare `std` is Kairo's (`kairo::std`, §2.1), so
C++'s needs a spelling of its own. Once per TU with any ffi import, phase I
synthesizes a `ModuleDecl` named `cxx` owning exactly ONE binding: `std` ->
every top-level `std` ModuleDecl in that TU's ffi closure, collected while
`_resolve_ffi` folds each closure header (for the aliased shape too -- an
aliased ffi import still puts C++'s std in the closure). It folds into the
overlay as a `ModuleHandle` under the key `cxx`. A TU with no ffi import binds
nothing and `cxx::std` is an ordinary miss.

It is a TRANSPARENT alias: it binds a name and nothing else. The decls it
reaches are the header TUs' own, they keep their own DC chains and their own
paths, and codegen spells them `::std::…` exactly as it did when bare `std`
reached them. Nothing after I knows the overlay exists.

No new lookup arm. `cxx::std::cout` walks the path that already exists: `cxx`
is a Module anchor (`module_scopes` on a ring of one yields its own scope),
`std` under it is an all-module cell -- §4.3's multi-scope rule -- and `cout`
searches every reopening. If ChainBinding or TypeResolve's `mods` walk ever
needs a change for this, that is a bug in the reopened-namespace support and
is fixed there.

`_fold_all_cells` takes a `skip_std` flag rather than checking the name
inline, because it has three callers: the bare ffi fold, `import foo::*`, and
a `*` item in a selective import. Only the first passes true. Every other
top-level C++ name folds as before, so `boost::`, `absl::` and friends are
unaffected -- `cxx` is one alias for one name, not a general prefix.

`cxx` used alone as a value or a type is `R053E`: "'cxx' names the C++ std
overlay; write `cxx::std`". A user shadowing `cxx` with their own module or
root is legal and not diagnosed. This is the one SymbolTable built outside
`ASTParse::_build_symbols`; it holds foreign decls by reference, never copies,
and is frozen before anything reads it -- the same shape `OverlayEntry::merged`
already has, so hard invariant #2 stands.

Note for Stage 1.5: the ~750 `libcxx::` sites in the compiler's own source are
a Stage 0 bootstrap namespace with nothing behind them in Stage 1 resolution.
Their target spelling is `cxx::std::`, not `std::`.
    N/T/CB   nothing special. Cross-TU probes spell through in_scope; a
             header TU has an ImmediateTable (TCM::ensure_imm_table) and no
             tokens.
    typer    a C `...` tail ranks Converted, unchecked (OverloadResolution);
             an `explicit` ctor is not a converting ctor (CastTyping 5d);
             ADL (MemberLookup::associated_scopes) finds `std::op <<`.
    codegen  CodegenBackend::run mounts each set's PCH in the backend's
             in-memory VFS and loads the MAIN file's set as the implicit
             PCH; a header's decls are never re-emitted (EmitPlan::_admit).

**Unresolved header.** A spelling clang cannot find leaves resolved_fid 0
and phase I binds nothing, so each use of its names is an ordinary R020E
miss. The set's own clang diagnostics go through a ClangDiagAdapter into
the Kairo engine (HeaderSet::begin_diag), mapping locations through the
set's cfid_to_kfid table: at build time into the set's diag_buf, drained
into the driver's engine once the build joins (those predate the header
fids, so they carry clang's file:line:col in their text), and during a fill
into the demanding TU's sink with real spans. The TextDiagnosticPrinter is
only the fallback client between them.

**The bare-ffi miss gate is gone**, and with it `NamedIdentExpr::foreign`,
`TraceRow::foreign_gate`, `AnchorKind::Foreign`, `MemberOutcome::Foreign`
and `OverlayTargetKind::FfiAnchor`. A typo in a TU with a bare ffi import
is a typo again.

**One PCH per clang TU.** A Kairo TU whose import graph spans two header
sets loads the main file's set as the PCH and `#include`s every other
set's headers textually by resolved path. Correct, just re-parsed.

**Instances of imported templates.** `cont<i32>` for an imported `cont` is a
registry shell like any instance (#12), but clang fills it, never M2
(`MemberLookup::filled_by_clang`). The first member lookup into the shell
calls `ForeignInstantiate::fill`: the registry entry's args are spelled back
as clang types in the primary's set (`TypeExport`), clang declares and
completes the specialization (`CheckTemplateIdType` + `RequireCompleteType`,
under the set's `sema_lock`), and DeclImport in fill mode imports the
ClassTemplateSpecializationDecl's members into the shell, which is then
`instantiated`. So `size()` returns clang's answer for `size_type`, not the
pattern's dependent spelling. The members LIVE in the primary's header
(scope, tables, bindings), but each name TOKEN is minted in the header it
is written in (`DeclImport::_home_at`): a token's text is read back through
its range's TU, and a name interned in `<__fwd/vector.h>` but ranged in
`<__vector/vector.h>` rendered as whatever identifier held that index
there (`.size` as `cend`). A fill that cannot run -- an arg with no clang
spelling (a Kairo-native record, a decl from another set), or a
specialization clang rejects -- is sticky (`foreign_fill_failed`) and lookup
walks the pattern, as it did before fills existed.

[DONE] The fill trigger is ONE entry point, `MemberLookup::ensure_filled`,
called by both readers of a shell's table: member lookup (`c.size`) and
TypeResolve's `::` step (`TypeResolve::_scope_of`), so an alias target, a
generic argument and a bare `X<A>::Y` in a signature all fill from the same
place. A `Foo<Args>::Y` whose `Foo` is imported and whose args are concrete
steps into the registry instance rather than deferring as dependent; it
defers only when the fill failed (its table is empty and the pattern's
spellings are dependent). Fills nest (define imports a type that is a path
into another shell): `ForeignInstantiate::_mu` and the set's `sema_lock` are
recursive, and a shell already mid-fill on this thread returns false at once.

A failed fill's clang errors reach the demanding TU's sink through the
engine, spanned in the header. [MISSING] a Kairo note pointing at the USE
that demanded the fill; a C++ forward
shape for Kairo-native args (`std::vector<KairoStruct>`).

**Nested records.** Implicit instantiation of `holder<alloc>` DECLARES
`holder<alloc>::node` but defines it only when something requires it
complete, so walk_declare (correctly) declares `node` and walks nothing in
it. The fill then completes every nested record its OWN walk reached --
an incomplete CXXRecordDecl instantiated from a member class of the
specialization -- with `RequireCompleteType`, under the locks the fill
already holds, and walks it into the same list before the define pass
(`ForeignInstantiate::_complete_nested`). A completed record's own nested
records join the list, so `A<T>::B::C` completes to any depth (a visited set
on clang decls; an ICE if it passes 4096). Records a member SIGNATURE merely
mentions are not reached and stay on demand -- completing transitively would
have the first <vector> fill instantiate half of libc++. A record clang
cannot complete is left memberless and logged, like a failed fill. Each
nested record is declared under its own USR into the shell's table, so
`holder<alloc>::node` from any TU is the one decl. Instances of nested
templates (`outer<alloc>::inner<i32>`) are ordinary registry shells and fill
on their own trigger.

**Lifetime.** Header TUs live for the build (CompilerInstance::release
refuses one). A set's clang instance lives until HeaderSetCache::release_all
at the end of execute(); per-set release once its last importer passes
Checked is the refinement. Fills need it alive: ForeignInstantiate ICEs on
a released set rather than read a dangling `clang_decl`.

---

## 6. Codegen: EmitPlan

Per emitted TU, produce the declarations a header would have provided.
Reads sema's links. Reads no `ImportDecl` except for §5.

### 6.1 Root set [DONE]

RAV over this TU. Collect the canonical redecl link of every decl reached
through `NamedIdentExpr::resolved_decl`, `ChainExpr::Step::resolved_decl`,
every entry of a `candidate_cell`, and every `Type::canonical` that is a
`RecordType` (its `decl`). Keep those whose DC chain bottoms out in a
different fid. Skip decls imported from a C++ header (`is_imported()`):
the header declares them.

### 6.2 Closure [DONE]

Repeat until no growth. Two edge kinds:

    fwd      : the target need only be declared (`class X;`)
    complete : the target's full body-less definition must precede

    FunctionDecl   -> param types, return type            : fwd
    Class/Struct   -> bases                               : complete
                   -> by-value field types                : complete
                   -> pointer/nullable field pointees     : fwd
                   -> method signature types              : fwd
                   -> nested types                        : part of this definition
    Union          -> field types                         : complete
    Enum           -> underlying                          : nothing (builtin)
    TypeAlias      -> target                              : complete
    generic primary-> as its kind, interface only

Whole class or nothing (invariant 11). `main` never imported `bar`, but
`foo::F` holds a `bar::B` by value => `B` lands in main.cpp. That is what
"bar depends on something foo brought in" means and it is handled here, not
by import order.

### 6.3 Ordering [DONE]

    Tier 0  every type in the set as a forward declaration, grouped by
            namespace. Breaks all pointer cycles up front.
    Tier 1  type definitions, topologically sorted on `complete` edges
            only. A cycle is a Kairo error owned by TypeCycleCheck [DONE];
            the plan asserts.
    Tier 2  function declarations. Any order.

Tie-break inside a tier: (source fid, source order). Output is
deterministic.

### 6.4 Namespace wrapping [DONE]

Each decl in `namespace a::b { ... }`, from `CXXSpell::ns_segments` (§3
invariant 9a). Reopening is free in C++, so one wrapper per decl is
correct; InterfaceEmitter merges consecutive same-namespace tier-0 entries,
EmitIR does not merge at all. Entry-TU decls go in the UNNAMED namespace,
not the global one -- `main` excepted, which C++ requires at global scope
and which therefore gets no declaration in the interface at all.

### 6.5 Alias tail [DECIDED: none]

After the interface block, TU-local only, never exported:

    import foo as f              -> namespace f = foo;
    import foo::add as my_add    -> using my_add = ...;  (types)
                                    inline auto& my_add = foo::add; (values, or just qualify at use)
    import foo::*                -> using namespace foo;  (or qualify at use)

[DECIDED] No alias tail. `TokenSink` prints every use fully qualified from
`resolved_decl`. The alias tail exists only to make the generated C++ read
like the Kairo, which is worth nothing against invariant 10 (an alias is
TU-local and never appears in an exported interface) and costs a second
naming mechanism codegen would have to keep consistent with the first.
Qualified-at-use is fewer moving parts; do not relitigate.

Use-site exactness is codegen's: every argument whose type differs from the
parameter's canonical is cast to it (CODEGEN.md §6), so C++ overload
resolution has one Exact candidate.

### 6.6 Emitter reuse [DONE]

`InterfaceEmitter(plan) -> EmitSink` (TokenSink for the build, TextSink for
`--print-cxx` and headers). Two callers:

    EmitPlan        roots = every own decl + foreign reached      (PlanMode::Preamble)
    EmitCXXHeader   roots = own `pub` decls + foreign reached     (PlanMode::Header)

Zero new logic for the header. A C++ consumer of the header sees canonical
namespaced names and nothing else.

---

## 7. Generics

[DECIDED] Kairo has no monomorphizer. Sema enumerates and checks every
`(template, canonical args)`; codegen emits explicit instantiations.

    home TU   : template <typename T> T add(T, T) { ... }   // body
                template i32 add<i32>(i32, i32);            // explicit instantiation DEFINITION
    other TUs : template <typename T> T add(T, T);          // interface: signature only
                extern template i32 add<i32>(i32, i32);     // explicit instantiation DECLARATION

Registry (the real content of M1/M2): `(template decl, canonical args) ->
home fid`, closed transitively over instantiations the body depends on.
Home = the template's own TU if it instantiates it, else the first user in
DAG order. Exactly one definition per instantiation build-wide; zero is a
link error, so the registry is authoritative.

`where` clauses, value-predicate `requires`, kind bounds, conformance:
checked in Kairo at the instantiation site, lowered (`WhereDispatchLowering`)
BEFORE emission. The emitted template is unconstrained and is only ever
instantiated at arguments Kairo accepted.

Note: template member bodies are emitted into the template's own TU always,
and into every TU that homes one of its instances (the explicit
instantiation definition needs the body visible). The header carries them.

Emission ORDER inside a TU follows from that. The `extern template`
DECLARATIONS stay in the preamble, where they have to precede any use, but
the explicit instantiation DEFINITIONS are emitted AFTER every body in the
TU. An explicit instantiation only instantiates the members that are
defined at the point it appears, so a definition emitted with the preamble
yields an instance with no members -- and the importing TU's `extern
template` then correctly refuses to supply its own, so the member is
missing at link time with no diagnostic anywhere. That is the whole reason
the Backend runs `InterfaceEmitter::emit_home_instantiations` as a second
pass after `EmitIR::emit_tu`, rather than emitting tier 3 with tiers 0-2.

---

## 8. Ordered work list

Each item is independently testable. Do them in this order.

    1. ImportDecl::file_seg_count stamped by PP           PP         DONE
    2. _fold_symbol_path; route multi-seg items through it  I        DONE
    3. ModuleHandle into `merged`                         I          DONE
    4. non_function_count exemption                       I          DONE
    5. Anchor.scopes, multi-module `::`                   CB         DONE
    6. Foreign anchor + Foreign outcome                   CB, trace  REMOVED by 15
    7. Bare-ffi miss gate in N                            N          REMOVED by 15
    8. Re-export fold                                     I          DONE
    9. Named roots: add_include(name), SearchRoot.name, module_base prefix   PP/Resolution DONE
   10. TypeCycleCheck                                     Sema/Check DONE
   11. EmitPlan collector + closure + tiers               Codegen    DONE
   12. InterfaceEmitter                                   Codegen    DONE (declarations and bodies)
   12b. Cross-fid TokenSink (locmap-translated locations) Codegen    DONE
   13. Instantiation registry + extern template           M1/M2      tier 3 extern/explicit DONE for classes; M1/M2 fill OPEN
   13a. Cross-reopening redefinition check (same signature, two definitions) at M2 sync
        OPEN, and not a codegen item: a module reopened in two files can define
        one signature twice, and nothing diagnoses it. Codegen cannot: each TU
        sees one half, emits it, and the collision surfaces as a LINKER
        duplicate-symbol error naming the mangled C++ name. Belongs in the M2
        sync point, where every TU's decls are visible at once; the error is
        N(a)'s (redefinition), with a note on the other definition.
   14. EmitCXXHeader via the same emitter                 Codegen    DONE
   15. Clang extraction pass (removes the §5 gate)        Interop, Sema/Foreign  DONE (§5)
   16. Per-TU object emission (_codegen loop, obj dir)    Codegen    DONE
   17. Builtin root + prelude                             PP/driver  DONE
   18. Container migration (items 2-9)                    Sema/Codegen  IN PROGRESS
   19. std root named `kairo::std` + bare-`std` prelude alias  Resolution/PP/driver  DONE
        Multi-segment SearchRoot::name, longest-first root matching,
        `module.k` at a root's top level naming the ROOT, PPResult::std_fid,
        the synthesized `import kairo::std as std`, and the prelude-handle
        eviction rule in _add. Tests: Tests/Sema/std_root.k,
        Tests/Sema/std_shadow.k.
   20. `cxx::std` overlay                                 I          DONE
        Tests: Tests/Sema/cxx_overlay.k, Tests/Sema/cxx_overlay_no_ffi.k.
        OPEN: the link test (a TU calling `cxx::std::strlen` and a
        `kairo::std` function in one body, compiled and run) needs std's own
        object on the link line, which the single-`-o` driver path does not
        emit for a graph TU yet.

Test for 1–9: `Tests/Sema/imports_all_forms`. `main.k` imports `foo.k`
under every form in §1, plus `module util` reopened across two files, plus
a re-export through `pub import bar::*`, plus an aliased ffi header.
`--print-sema` shows every head bound `[import overlay]` and every step
bound, the ffi one included, with exactly two diagnostics: a name behind a PRIVATE
import edge and one deliberate typo. `main.sema.golden` is the whole dump,
for diffing what a change did beyond the asserted lines. Named roots (9)
are covered separately: two roots each holding `a.k`, imported as `a` and
`foo::a`, binding to two different decls.

Test for 10: `Tests/Sema/type_cycle.k`. Five cycles (self, mutual, fixed
array + tuple, bases, a generic argument the template stores by value) and
five non-cycles (pointer, nullable, vector, map, set, plus a generic
argument the template only points at), in one file, with `DIAG-NOT` closing
the count. Both halves matter: the edge set is the whole content of the
pass, and the second half is what a naive "does it mention itself" check
gets wrong.

Test for 11: `Tests/Sema/emit_plan`. `main.k` imports `foo`, never `bar`;
`foo::F` holds a `bar::B` by value and a `bar::Deep` behind a pointer.
`--print-emit-plan` then has to show B in tier 1 (transitivity through a
file main never named), Deep in tier 0 only (edge strength), `foo::Unused`
nowhere (reachability), and B before F in tier 1 whatever order the two
files were written in. Those four are the four independent ways the plan
can be wrong.

Test for 12: foo.cpp + main.cpp compiled together with
`-fsanitize=undefined -Wodr`; main.cpp's preamble diffed against a
hand-written one.

Test for 13: a two-TU generic call that links.