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
| 8 | ffi bare | `ffi "c++" import "h.hh"` | nothing (the header's names are unqualified) |
| 9 | ffi aliased | `ffi "c++" import "h.hh" as my_h` | `my_h` -> FfiAnchor(the ImportDecl) |

Mixed forms (`import foo::{*, A as B}`) are (5) with a wildcard item, and
work by composition. `pub`/`prot` on any form is re-export (§4.4).

**The importer never learns which form was used.** By N, all seven look
identical: an overlay entry keyed by this TU's imm, holding targets.

---

## 2. Pipeline: what happens at each stage

    PP     resolve import PATHS to fids; stamp the node       [DONE, one gap]
    Index  hoist decl heads for parser disambiguation         [DONE]
    Parse  build AST; freeze per-DC symbol tables             [DONE]
    I      ImportResolution: build this TU's overlay          [DONE, three bugs]
    N      NameResolution: bind heads through the overlay     [DONE]
    T      TypeResolution: canonicalize types                 [DONE]
    CB     ChainBinding: bind `::` and `.` steps              [DONE, one gap]
    ...
    EP     EmitPlan: regenerate the per-TU C++ interface      [MISSING]
    CG     TokenSink: emit                                    [needs one rule]

### 2.1 PP path resolution

`Preprocessor/FileImportIndex.k` walks the import graph, resolves each path
through `ImportResolver` (file-first: `foo.k`, fallback `foo/module.k`;
`import module` is fallback-only), loads the file, and stamps
`ImportDecl::resolved_fid`. It also records `TranslationUnit::import_edges`
(fid, decl) in declaration order. **The PP is the one writer of path->file.**
Phase I never touches the filesystem.

[BROKEN] `import foo::MyClass`: the PP resolves `foo` as the file and knows
`MyClass` is a trailing symbol, but records only `resolved_fid`. I cannot
tell a symbol path from a two-segment module path. Fix: add

    ImportDecl::file_seg_count: u32   // leading segments that named the FILE

stamped next to `resolved_fid`. `== path_segments.size()` for a plain module
import. See §4.1.

[DECIDED] **Module roots and paths.**

A module path is `[root name] + directories + file`, and every part of
that is fixed by where the file sits, never by who imports it.

- **Every root has a name; the name is the leading segment.** `-I ~/foo`
  registers a root named `foo` (the directory basename; `-I name=path`
  overrides). `import foo::a` resolves to `~/foo/a.k`, whose module path
  is `foo::a`. `module.k` names its directory; `module X { }` inside a
  file appends `X`.
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

Mechanically: `ImportResolver::Builder::add_include` takes a name;
`SearchRoot` carries it; `module_base` for a file under a root is
`[root name] + relative directories`; the entry root passes an empty
name. Verify with a two-root test where both roots contain `a.k`.

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

[BROKEN] Three defects in I, all small:

1. `_rebuild_merged` excludes `ModuleHandle` targets from the `merged`
   cell that `NameLookup::unqualified` reads. So `foo` after `import foo`
   resolves to an EMPTY cell and N reports it undeclared. A module handle
   is a legitimate lookup answer (a name denoting a scope). Include it.
2. `OverlayEntry::non_function_count` counts `ModuleHandle` as a
   non-function target, so two files reopening `module util` imported by
   the same TU are diagnosed as an ambiguous import. They are one
   namespace. Exempt `ModuleHandle` (and `FfiAnchor`).
3. Symbol-path imports (§1 forms 3, 4, and multi-segment items in 5)
   fold as module handles named after the last segment. See §4.1.

[MISSING] Re-export. `pub import` / `prot import` sets a visibility bit
that nothing reads. See §4.4.

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

[BROKEN] Reopened namespaces: with I fix #2 the overlay hands N a cell of
N `ModuleDecl`s; N cannot collapse them (distinct canonicals) and defers;
ChainBinding treats a deferred head as "needs inference". Fix: an all-
`ModuleDecl` candidate set is a `Module` anchor with N scopes; `::` steps
search all of them; a hit in two is a genuine ambiguity (already
diagnosed by `_commit`). `Anchor.scope` becomes `Anchor.scopes`.

[MISSING] `Foreign` anchor for ffi. See §5.

### 2.7 EP EmitPlan [MISSING]

The codegen half. Specified fully in §6.

---

## 3. Invariants (add to RESOLUTION.md §3)

8. **Imports are erased.** No pass after N/CB reads an `ImportDecl` except
   to find `FfiAnchor`s and the ffi `#include` list. A codegen decision
   that needs "how was this imported" is a bug; ask the decl where it lives.
9. **One namespace per decl, derived, never stored per use.** A decl's C++
   namespace is its DC parent chain -> `ModuleDecl::module_path`. Every TU
   that emits that decl computes the same path from the same node.
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

### 4.1 Symbol-path imports [BROKEN -> specified]

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
else.

### 4.2 Module handles in `merged` [BROKEN -> one line]

`_rebuild_merged`: append `t.decl` for `Type`, `ModuleHandle`, and
`FfiAnchor` targets. Only `FunctionSet` unions cells.

### 4.3 Reopened namespaces [BROKEN -> two edits]

`non_function_count`: skip `ModuleHandle` and `FfiAnchor`.
ChainBinding: `Anchor.scopes: vec<*DeclContext>`; all-module candidate
sets become a multi-scope `Module` anchor; `::` searches every scope.

### 4.4 Re-export [MISSING]

RESOLUTION.md §2 already decides the rule: a `pub`/`prot` import is
surface. In `_resolve_one`, after folding `src_tu->symbols()`, also walk
`src_tu->import_overlay->collect_rows()` and fold every target whose
`origin` ImportDecl `is_public()` (or `is_protected()`), carrying the
target's own `vis` fact forward. Wall 1 holds: a `priv` import edge in the
source is never folded. DAG order guarantees the source overlay is
complete. ~40 lines in I.

### 4.5 Protected-import enforcement [MISSING]

Needs member-lookup provenance (same library?). Home: `AccessCheck.k`,
after ChainBinding. Not an import problem; listed for completeness.

---

## 5. ffi imports

[DECIDED] An ffi import is a `#include` plus, optionally, a Kairo-side
*scope fiction*. The header's declarations exist only inside clang until the
extraction pass (`Interop/Clang`, post-I, [MISSING], large) hangs real
`Decl`s off the anchor.

Until then, the model that is correct now and stays correct later:

**Aliased (`as my_h`).** `my_h` binds to the `ImportDecl` (needs §4.2).
ChainBinding gets `AnchorKind::Foreign`; every step after a Foreign anchor
records `MemberOutcome::Foreign`: no decl, no diagnostic, no poison, chain
flagged so inference stops there. Codegen emits `my_h::use()` as `use()` 
the prefix is stripped, not translated, because the header was included and
C++ resolves `use` itself. That is why it works when the header declares no
namespace. When extraction lands, Foreign steps get real decls; nothing
upstream changes.

**Bare (no alias).** The header's names are in unqualified scope, so a bare
`use()` must resolve, and today N reports it undeclared. The only option
without extraction: on an unqualified miss, if THIS TU has a bare ffi
import, mark the use Foreign instead of erroring. This turns typos into
deferred clang errors the exact failure the frontend exists to prevent 
so it is gated on the presence of a bare ffi import in this TU, documented
as temporary, and extraction is the thing that removes the gate, not an
optional improvement.

**Codegen.** Every ffi `ImportDecl` in the TU (and, transitively, in every
TU whose decls this TU emits an interface for? no: only THIS TU's, because
foreign decls are never re-emitted by Kairo) becomes one `#include` at the
top of the emitted C++. Order: declaration order.

---

## 6. Codegen: EmitPlan [MISSING full spec]

Per emitted TU, produce the declarations a header would have provided.
Reads sema's links. Reads no `ImportDecl` except for §5.

### 6.1 Root set

RAV over this TU. Collect the canonical redecl link of every decl reached
through `NamedIdentExpr::resolved_decl`, `ChainExpr::Step::resolved_decl`,
every entry of a `candidate_cell`, and every `Type::canonical` that is a
`RecordType` (its `decl`). Keep those whose DC chain bottoms out in a
different fid. Skip `FfiAnchor` ImportDecls and Foreign steps.

### 6.2 Closure

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

### 6.3 Ordering

    Tier 0  every type in the set as a forward declaration, grouped by
            namespace. Breaks all pointer cycles up front.
    Tier 1  type definitions, topologically sorted on `complete` edges
            only. A cycle is a Kairo error owned by TypeCycleCheck; the
            plan asserts.
    Tier 2  function declarations. Any order.

Tie-break inside a tier: (source fid, source order). Output is
deterministic.

### 6.4 Namespace wrapping

Each decl in `namespace a { namespace b { ... } }` from `module_path`.
Reopening is free in C++; one wrapper per decl is correct, merging
consecutive same-path decls is cosmetic. Root TU decls: global namespace.

### 6.5 Alias tail

After the interface block, TU-local only, never exported:

    import foo as f              -> namespace f = foo;
    import foo::add as my_add    -> using my_add = ...;  (types)
                                    inline auto& my_add = foo::add; (values, or just qualify at use)
    import foo::*                -> using namespace foo;  (or qualify at use)

Simplest correct choice: emit NO alias tail and have `TokenSink` print every
use fully qualified from `resolved_decl`. The alias tail exists only if you
want the generated C++ to read like the Kairo. Decide once; qualified-at-use
is fewer moving parts.

### 6.6 Emitter reuse

`InterfaceEmitter(roots) -> token stream`. Two callers:

    EmitPlan        roots = foreign decls used by this TU
    EmitCXXHeader   roots = this module's `pub` decls   (the C++ interop header)

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

---

## 8. Ordered work list

Each item is independently testable. Do them in this order.

    1. ImportDecl::file_seg_count stamped by PP           PP         ~10 lines
    2. _fold_symbol_path; route multi-seg items through it  I        ~40 lines
    3. ModuleHandle + FfiAnchor into `merged`             I          1 line
    4. non_function_count exemption                       I          1 line
    5. Anchor.scopes, multi-module `::`                   CB         ~30 lines
    6. Foreign anchor + Foreign outcome                   CB, trace  ~40 lines
    7. Bare-ffi miss gate in N                            N          ~15 lines
    8. Re-export fold                                     I          ~40 lines
    9. Named roots: add_include(name), SearchRoot.name, module_base prefix; two-root test      PP/Resolution ~30 lines
   10. TypeCycleCheck                                     Sema/Check ~80 lines
   11. EmitPlan collector + closure + tiers               Codegen    the real work
   12. Out-of-line body rule                              TokenSink
   13. Instantiation registry + extern template           M1/M2
   13a. Cross-reopening redefinition check (same signature, two definitions) at M2 sync
   14. EmitCXXHeader via the same emitter                 Codegen    ~20 lines
   15. Clang extraction pass (removes the §5 gate)        Interop    large

Test for 1–8: `main.k` importing `foo.k` under every form in §1, plus two
files reopening `module util`, plus an aliased ffi header. `--print-sema`
must show every head bound `[import overlay]` and every step bound, with
exactly one diagnostic for one deliberate typo.

Test for 11–12: foo.cpp + main.cpp compiled together with
`-fsanitize=undefined -Wodr`; main.cpp's preamble diffed against a
hand-written one.

Test for 13: a two-TU generic call that links.