# Incremental AST and Sema

The design for re-using parse and Sema results: across runs (a build that
skips Sema for what did not change) and inside one process (an editor that
re-checks one file, not the program). [Incremental.md](Incremental.md) is the
object cache, which exists; this page is its "Phase 2" and the part after it.
[Serialization.md](Serialization.md) is the on-disk format.

**Status.** Phases 0, 1 and 2 are built. Of phase 3 the re-check plan is built
and proven against full runs; loading interfaces is not, and cannot be from
what a record holds ([Phase 3](#phase-3-the-re-check-plan-and-what-blocks-the-rest)).
Phases 4 and 5 are built as the live check ([Phases](#phases)). The compiler
flag `--incremental-sema` (module records and the all-hit skip) is off unless
given; the language server's live check (`initializationOptions.liveCheck`)
is on by default. They are different switches. The four changes to Sema and
the persistent preamble are design.

## What it has to deliver

| | Without reuse | Target |
|---|---|---|
| No-change build of the compiler's tree | about 13 s: Sema 7 s, key fill 2.7 s, link 2.7 s | the link, plus loading records |
| One body edited | Sema of 363 files, codegen of 1 | parse and Sema of 1 file, codegen of 1 |
| One signature edited | the same | that file and the files that read the signature |
| Editor, after a keystroke in a file nothing imports | a new process and 9.4 s (release) | under 150 ms, in a process that stays up |

## Why it is not a cache bolted on

Measured and read from the code:

1. **Sema writes outside the file it is checking.** The canonical type
   store, the instantiation registry, conformance rows, tuple records and the
   foreign registry are build-wide, keyed by raw pointers, and have no
   removal and no record of which file caused an entry.
2. **Much of that state is one-shot.** An instance is checked once, made live
   once, has its panic set solved once; a nullable is lowered once; ranks only
   grow. A second check of one file meets its own old entries.
3. **Files point into each other with raw pointers, in both directions.** An
   importer's `resolved_decl` points into the importee; an out-of-line
   definition is spliced into another file's redeclaration ring; lowering
   stamps a default-argument thunk onto another file's parameter.
4. **Importers read the importee's LOWERED tree**, and lowering is
   destructive (it moves a default expression into a thunk), so it cannot be
   run twice on one tree and cannot be skipped for a file something imports.
5. **Nothing identifies a declaration across processes.** Only imported C++
   declarations have a USR. Canonical types are identified by address.
6. **There is no interface hash before codegen.** The object key is the hash
   of the C++ token stream, which needs the whole checked and lowered tree.

A design that ignores any of these is either wrong (a false hit is a
miscompile) or is a restart in disguise.

## The model

**A module record** is everything Sema knows about one file, in a form that
can be stored, loaded and replaced:

- the parsed tree ([Serialization.md](Serialization.md));
- its **interface**: per exported declaration, the signature, layout and
  every inferred fact an importer can read (purity, panic set, parameter
  passing, default-argument thunks, nullable layout);
- its **body facts**: what Sema wrote that only this file and codegen read;
- its **dependencies**: what it read from other modules (below);
- its diagnostics, attributed to it.

**Identity.** A declaration has a `DeclId`: module path, the path of scopes
down to it, name, kind, and for a function its parameter types as written.
It is a value, stable across processes and across edits that do not rename.
A canonical type's stored form is structural (builtins by kind, records by
`DeclId` and arguments). Pointers remain the in-memory representation;
`DeclId` is what crosses a file or process boundary.

**Dependencies are recorded where they are made.** While file X is checked,
every read of another file is logged against X:

| Read | Logged as | Invalidated by |
|---|---|---|
| a name looked up in a scope of file F (found or not) | `(F, scope, name)` | any declaration of that name added to, removed from or changed in that scope |
| a declaration's signature, layout or inferred fact | `(DeclId, which)` | that part of the declaration's interface hash changing |
| a body: an inline or generic body instantiated, an `eval` function run | `(DeclId, body)` | the body's hash changing |

The name-level rows are what make "a new overload appeared" correct: the
file that would now resolve differently has a row for that name even though
it never touched the new declaration.

**Interface hashes.** `I(decl)` is computed at `SemaPhase::Checked` from the
declaration's interface as defined above, never from the lowered C++ stream.
`I(m)` combines a module's. A record's key is
`M(m) = H(F_sema, source(m), the logged reads' current hashes)`: computable
without checking `m`, given its dependencies' records.

## Phase 1: identity, interface hashes, the dependency log

**Built.** Phase 1 reuses nothing itself: it computes the facts, prints them
(`--dump-interface`, `--dump-deps`) and proves the log complete against a
brute-force oracle. With neither flag no log exists and Sema does what it
did; the lookup path pays one thread-local load and a null test.

Code: `Compiler/AST/Context/DepLog.k` (the log and its per-thread current
pointer), `Compiler/Sema/Incremental/Facts.k` (DeclId, the interface, the
rows), `FrontendAction::_dump_incremental` (the two files),
`Scripts/incr_oracle.py` (the oracle), `Tests/Sema/Incremental/` (the tests
and the scenario project).

### DeclId

`<module>#<scope>/.../<declaration>`, a string; its hash is xxh3-128 of the
string (`incr_hash`). No address, fid or imm index goes into it.

- **module**: the module path of the file the declaration's scope chain ends
  in, spelled (`Sema::Resolve::NameLookup`). A file outside every root is
  `~<stem>`. A member defined out of line in another file therefore has its
  class's id, and both files list it.
- **each scope and the declaration itself**: `<kind>:<name>`, kind as
  `--print-sema` prints it (`fn`, `var`, `field`, `class`, `struct`, `union`,
  `enum`, `variant`, `interface`, `type`, `module`). The file's implicit
  module is not a segment. An extension is `ext:<target type as written>`.
- **what tells same-named declarations apart**: `<n>` for n generic
  parameters; `<args>` for a specialization's arguments as written; for a
  function `(<parameter types as written>)` with `self` for the receiver and
  `...` after a pack; for `op as`, `-><result type as written>`.
- An operator's name is `op <tokens>`; a constructor's is the type's name.
- An implicit instance is named as its pattern. A C++ declaration has no
  DeclId (it has a USR); `c++:<name>` only keeps a type string readable.

Examples:

| Declaration | DeclId |
|---|---|
| `pub fn add(a: i64, b: i64) -> i64` in `lib.k` | `lib#fn:add(i64,i64)` |
| `pub fn op + (self, o: i32) -> i32` in `class Box` | `lib#class:Box/fn:op +(self,i32)` |
| `pub fn sum(self) -> i32` in `extend P` | `lib#ext:P/fn:sum(self)` |
| `pub fn <T> ident(v: T) -> T` | `lib#fn:ident<1>(T)` |
| `NameLookup::tu_of` in the compiler | `Sema::Resolve::NameLookup#class:NameLookup/fn:tu_of(unsafe *DeclContext)` |

A written type is the text of its type node; a pointer node starts at its
`*`, so the `unsafe` before it is added back (the last row). Parameter types are **as written**: the id exists before Sema and is what change 3 will match on; `Id` and `i32`
for one type are two ids, and the cost is a re-check. Two declarations can
still share an id (a member's declaration and its out-of-line definition, the
arms of a `where` group, an erroneous redefinition): the interface then lists
the id more than once and a reader compares the sorted list. On the
compiler's own tree 26 of 23 073 listed declarations share an id (13 ids).

A **type's structural string** is its canonical type as Kairo writes it,
then `@` and the DeclId of every record in it in order of appearance:
`*Point@shapes#struct:Point`. Canonical, so an alias is its target.

### What is in `I`

`I(decl)` is xxh3-128 over `kind | lookup name | effective visibility` and:

| Declaration | Hashed |
|---|---|
| function | the header as written, whitespace-normalized, from its first token to its body (generic parameters and bounds, parameter names, modes and defaults, `requires`, `where`, the declared panic set); then per parameter its mode, `const` and structural type; the structural return type (the inferred one for an expression body); `PanicSetState` and the declared and SOLVED panic sets; the modifier bits (`const`, `unsafe`, `eval`, `async`, `final`, `panic`, `inline`), the body kind, transfer kind, calling convention, generator, yield, noreturn, variadic and no-unwind bits. An `inline` function also hashes its body: every importer compiles it. |
| variable, constant | storage, the whole declaration as written (so the initializer an importer can fold through), the structural type (inferred or written) |
| field | name, visibility, storage, the declaration as written, the structural type |
| enum variant | the variant as written, its folded value, its payload types |
| type alias | the declaration as written, the structural type of its target |
| class, struct, union, enum, interface (its **layout**) | generic parameters and bounds and `requires` as written; each base and implemented interface with its visibility and structural type; every field in order (as above); for an enum the underlying type and every variant in order (as above); for an interface every requirement's signature; `final` / abstract; and the members found by role and not by name: constructors, operators, and methods that are `= virtual`, `= default` or `= delete` |
| module | nothing more (its members are entries of their own) |

**Not in `I`**: a body (it has its own hash); a declaration's position; a
method found by name (it is its own entry, so adding one does not move the
type's `I`); anything Sema learns after `Checked`: inferred purity, inferred
parameter passing, default-argument thunks, field-initializer folds, enum and
nullable layout. Phase 2 needs those (see the end of this section).

**The body hash** is xxh3-128 of the body's text, whitespace-normalized,
from the `{` or the expression after `=` to the end of the declaration; empty
when there is none. It is recorded for every function. Who reads it is the
log's business: a plain function's body has no reader.

**Visibility does not filter.** Every declaration a scope's symbol table
names is listed, `priv` ones too: an importer's lookup finds a private name
and reports it, and overload resolution ranks a private candidate before
access is checked.

`I(m)` is xxh3-128 over the module path, the hash of the file's macro
definitions, the sorted `DeclId, I, body hash` lines, and the sorted
per-scope name sets. A name set is the keys of a scope's symbol table:
identifiers, `op#<token kinds>`, `<ctor>`, `<dtor>`; an extension's scope
also carries the type it extends.

### Dependency rows

One `DepLog` per TU, written only by the thread running that TU's Sema.
`DepLogScope` makes it the thread's current log in `Sema::run_to`,
`Sema::resolve_types_pre` and around the driver's `refold_reexports`; the
chokepoints below read the current log. Rows hold addresses and keys and are
resolved to strings at the end of the frontend. A read of the TU's own tables
is not a row.

| Row | Logged in | Meaning |
|---|---|---|
| name `(module, scope DeclId or "", name)` | `SymbolTable::lookup` (which `lookup_ident`, `DeclContext::lookup_symbol*`, `NameLookup`, `MemberLookup` and every direct caller end in) and `SymbolTable::lookup_foreign` for a spelling the source never interned | this scope of that file was asked for this name, found or not |
| overlay `(module whose overlay, name)` | `ImportOverlay::lookup_ident`, `ImportOverlay::entry` | an unqualified name reached an import overlay, hit or miss; the overlay stands for the file scope of every file in its **surface** (the file's imports, then what those re-export, transitively), which the dump lists per file. A hit also logs a name row for each declaration found, under its declared name (the key may be an import alias) |
| declaration `(DeclId, sig)` | `IncrFacts` walking the checked tree: every resolved `NamedIdentExpr`, variant and chain step | the declaration's `I` was read |
| declaration `(DeclId, layout)` | the same walk: every record in the canonical type of every type node, expression, chain step and inferred slot | a value of the type exists here: its size, copyability, initialization and variants were read |
| declaration `(DeclId, body)` | `InstantiationRegistry::instance_for` (every request, not only the minting one), `ConstEval::_ref` (a constant folded through), and the walk for a reference to a generic, a member of a generic type, or an `inline` / `eval` function | the body (or initializer) was read |

Rows into a C++ header's scopes are dropped: a header is keyed whole, by its
content hash.

`__builtin_is_declared<P>()` logs its lookups as ordinary name and overlay
rows, misses included (a spelling the asking file never interned is interned
or goes through `lookup_foreign`), and so does the per-file test of a
conditional extension. A changed header or a changed set of `ffi` imports is
a full check, so a header that gains `#include <string>` with no `.k` edit is
covered.

Not logged, on purpose: the effect barrier (`EffectTable::solve`, on the
driver, between `Typed` and `Checked`) reads callees' panic sets across
files with no log scope. What it computes is in `I` (the solved set of every
function), and a caller already has a name or signature row on each callee,
so a changed set re-checks the caller through that row.

### Invalidation rules

What `Scripts/incr_oracle.py` implements, and what phase 2's key must be
equivalent to. File X is re-checked when:

- **R0** X was edited.
- **R1** X has a name row `(M, scope, name)` and the declarations of that
  name in that scope of M differ: one added, removed, or with a different
  `I`. A row on a type's scope (or on an extension's) also reads the
  same-named members of every extension of that type, in whatever file.
- **R2** X has an overlay row `(H, name)` and a file in H's surface changed
  that name at file scope; or H's surface itself changed.
- **R3** X has a declaration row: `sig` and `I` changed; `layout` and `I`
  changed for the record or for any record its layout names (closed over the
  `refs` each entry lists); `body` and the body hash or `I` changed.
- **R4** A name appeared at or disappeared from the file scope of a file in
  X's surface while another file in X's surface (or X) declares it: an import
  collision, which I reports without any use.
- **R5** X has a body row into a file that is itself re-checked.
- **R6** X has a body row into a file G, and G names a declaration whose
  body changed. (No scenario exercises R6 yet: every chain tried was already
  caught by R1 or R3. It is there for a dependent inferred return type read
  through two generic layers by a file that is not the instance's first
  namer.)
- **R7** The macro definitions of a file in X's surface changed.

### The dumps

Both are one JSON object, `{"version": 1, "root": <working directory>,
"files": [...]}`, files sorted by module path, every list sorted, no absolute
path but `root`. A file's `path` is relative to `root`, or empty outside it.

- `--dump-interface`: per file `module`, `path`, `phase`, `hash` (`I(m)`),
  `macros`, `decls` (`id`, `scope`, `name`, `kind`, `I`, `body`, `ext` for an
  extension member, `refs`: the DeclIds its types name) and `scopes`
  (`scope`, `ext`, `names`).
- `--dump-deps`: per file `module`, `path`, `surface`, `names`, `overlay`
  (`of`, `names`) and `decls` (`id`, `part`).

### The oracle

`Scripts/incr_oracle.py` takes a project and a list of edits. Per edit it
dumps before, applies the edit, dumps after, predicts the re-check set from
the BEFORE rows and the interface diff, and compares every other file's
`--print-sema` section and diagnostics byte for byte. A predicted-unaffected
file that differs is a hole, named with the edit, and the exit code is 1.
A scenario may pin its exact re-check set (`expect`).

`--print-sema` prints the position of every declaration it names, and a
position is not in `I`, so an edit must keep the line count (the scenario
files replace `// SLOT` comment lines to add a declaration); `"line_shift":
true` compares with positions normalized instead.

Results (debug compiler). `Tests/Sema/Incremental/Inputs/proj`,
44 scenarios over 76 files, zero holes (`Tests/Sema/Incremental/oracle.k` runs them):

| Scenario | Predicted | Actually changed | Over-invalidated | Verdict |
|---|---|---|---|---|
| `body_plain` | 1 | 1 | 0 | ok |
| `signature` | 4 | 4 | 0 | ok |
| `overload_picked` | 2 | 2 | 0 | ok |
| `overload_unpicked` | 2 | 2 | 0 | ok |
| `remove_decl` | 2 | 2 | 0 | ok |
| `field_type` | 10 | 4 | 5 | ok |
| `field_added` | 10 | 1 | 9 | ok |
| `fields_reordered` | 10 | 5 | 5 | ok |
| `private_method` | 1 | 1 | 0 | ok |
| `private_field` | 2 | 0 | 1 | ok |
| `generic_body` | 5 | 1 | 4 | ok |
| `eval_const_value` | 3 | 0 | 2 | ok |
| `eval_fn_body` | 2 | 0 | 1 | ok |
| `enum_discriminant` | 2 | 1 | 1 | ok |
| `enum_variant_renamed` | 2 | 2 | 0 | ok |
| `type_alias` | 4 | 3 | 0 | ok |
| `reexport_chain` | 2 | 2 | 0 | ok |
| `reexport_cut` | 3 | 1 | 1 | ok |
| `extension_method_added` | 2 | 2 | 0 | ok |
| `extension_block_added` | 2 | 2 | 0 | ok |
| `out_of_line_body` | 1 | 0 | 0 | ok |
| `out_of_line_decl_signature` | 3 | 2 | 0 | ok |
| `default_argument` | 2 | 0 | 1 | ok |
| `cycle_body` | 1 | 0 | 0 | ok |
| `cycle_signature` | 1 | 1 | 0 | ok |
| `cycle_signature_used` | 2 | 1 | 1 | ok |
| `inferred_return` | 5 | 4 | 0 | ok |
| `generic_body_transitive` | 5 | 1 | 4 | ok |
| `generic_signature_transitive` | 5 | 3 | 2 | ok |
| `interface_requirement_added` | 3 | 2 | 1 | ok |
| `base_method_signature` | 2 | 1 | 0 | ok |
| `base_method_added` | 1 | 1 | 0 | ok |
| `base_field_type` | 3 | 1 | 2 | ok |
| `operator_added` | 2 | 2 | 0 | ok |
| `operator_signature` | 2 | 2 | 0 | ok |
| `constructor_signature` | 2 | 2 | 0 | ok |
| `import_collision` | 2 | 2 | 0 | ok |
| `module_member_signature` | 2 | 2 | 0 | ok |
| `module_member_added` | 2 | 2 | 0 | ok |
| `aliased_import_signature` | 5 | 5 | 0 | ok |
| `private_made_public` | 2 | 2 | 0 | ok |
| `macro_body` | 2 | 1 | 0 | ok |
| `generic_inferred_transitive` | 4 | 4 | 0 | ok |
| `const_transitive` | 3 | 0 | 2 | ok |

The compiler's own tree (380 files), `Inputs/self_edits.json`:

| Edit | Predicted | Actually changed | Over-invalidated | Verdict |
|---|---|---|---|---|
| body of `shell_quote` (`Support/ShellQuote.k`) | 1 | 1 | 0 | ok |
| a defaulted parameter added to `IdentifierToken::as_string` | 2 | 2 | 0 | ok |
| a second `shell_quote` overload | 2 | 2 | 0 | ok |
| the initializer of `U16_MIN` (`Support/Limits.k`) | 1 | 1 | 0 | ok |
| a private field added to `Timer` | 12 | 1 | 11 | ok |
| an explicit discriminant on `FileOutMode::Read` | 1 | 1 | 0 | ok |

Three of the six (the body, the constant and the enum) have no reader in
another file, so they show only that nothing else moved. The eleven over-invalidated files of the `Timer` edit are R5: `ThreadPool` holds a `Timer` and is re-checked, and each of them reads an `inline` body of `ThreadPool`.

### Costs

On the compiler's own tree (380 files, debug compiler, `--type-check-only
--time-passes --threads 0`):

| | Sema region | Process CPU (user) | Wall | Peak RSS |
|---|---|---|---|---|
| baseline, without the phase | 43.2 s (41.4 to 44.3) | 53.1 s (52.9 to 53.8) | 37.9 s | 3.84 GB |
| after, flags off | 44.1 s (39.7 to 44.4) | 53.3 s (51.1 to 54.5) | 37.2 s | 3.83 GB |
| after, both dumps on | 46.1 s (42.7 to 48.3) | 57.3 s (56.4 to 57.8) | 39.9 s | 4.06 GB |

Median of three interleaved runs each, range in parentheses. Off is inside
the run-to-run noise of the baseline. On costs about 4 s of CPU (7%): the
logging itself, 1.1 s reading the checked trees (`IncrFacts`) and 0.45 s
resolving and writing the dumps (`IncrDump`), and 0.22 GB.

The dumps of that tree: 7.3 MB of interface (23 073 declarations in 1 386
scopes) and 9.5 MB of dependencies (54 731 name rows, 7 871 overlay names,
29 618 signature, 8 733 layout and 2 100 body rows). A wildcard import costs one overlay name per
name actually looked up, not one per name imported, because the overlay row
is expanded against the surface by the reader of the log and not stored per
source.

Determinism: the two dumps are byte-identical across two runs, and across
two copies of the tree in different directories except for the value of
`root` on the first line, when each copy carries its own `Lib/` and is given
it (`--builtins-dir`, `--std-dir`); a library outside `root` has an empty
`path`. The interface dump is also identical across import orders; the
dependency dump is not (open hole 9).

### Holes

Closed:

- **Macros.** A macro body edit changed its importer's tree and no row said
  so (scenario `macro_body`). Closed by the per-file macro hash and R7.
- **Wildcard collisions.** A wildcard import folds a file scope without
  probing any name, so a new type colliding with another import's had no row.
  Closed by R4 (`import_collision`).
- **Import aliases.** `import m::{scale as times}` probes the overlay for
  `times`, which no name set holds. Closed by logging each hit's declarations
  under their declared names (`aliased_import_signature`).
- **New extension block.** The first `extend Point` in a file has no scope
  for an earlier lookup to have probed. Closed by R1's extension clause,
  keyed by the extended type (`extension_block_added`).
- **Layouts by value.** `sizeof Outer` reads `Point` through a field with no
  lookup. Closed by `refs` and R3's closure (`field_type` on `use_outer_size`).
- **Later readers of an instance.** An instance is checked once, by its first
  namer; a second file naming it logged nothing from inside it. Closed by
  logging every request (`instance_for`) and by R5 / R6.

A scenario that passes without proving much: `const_transitive` (a constant
folded through a constant of a third file) is predicted through the body row
`ConstEval::_ref` logs, but `--print-sema` prints the extent by name, so the
brute-force side sees no change either way. The same holds for
`eval_const_value`, `eval_fn_body` and `default_argument`: predicted, not
observable in the dump.

Open:

1. **Positions.** A declaration's line and column are in no hash, and an
   importer's diagnostics (a note into the importee) and `--print-sema` name
   them. Rule R8 (phase 3) re-checks the reader of a position.
2. **Instance diagnostics belong to the first namer.** If the file that named
   an instance first stops naming it, its diagnostics move to another file
   whose rows did not change. This is finding 2 above (one-shot state) and
   goes away with change 1, not with a row.
3. **Extensions of non-record types** (`extend i32`) are found only through
   extension scopes that already exist: the first extension of such a type
   anywhere in the build has no row to invalidate.
4. **Facts after `Checked`** are not in `I` (listed under "Not in `I`").
   Print-sema and diagnostics do not depend on them, so the oracle cannot see
   them; object equality will.
5. **Graph changes.** A file added to or removed from the graph is outside
   the oracle (it refuses); an import added to a file is an edit of that file.
   Phase 2 treats every graph change as a miss (the importer's edit, or a
   listing change of a directory the graph resolves through).
6. **Name-level precision.** A record's `I` is its layout, so every file that
   names a type is re-checked when a field changes, including one that only
   holds a pointer to it. Splitting `I` into a name part and a layout part
   would stop that; nothing depends on it.
7. **Row dedupe** keys a (table, key) pair by a 64-bit mix: a collision would
   drop one row. Exact pairs cost a set node per lookup.
8. **Lang items** are filled once per build on the global table and read
   without a lookup. They come from the bundled library, which is part of
   `F_sema`; a user-declared lang item would have no row.
9. **Extension visibility.** The extension index is build-wide; it is
   filtered per TU by
   `MemberLookup::extension_visible` (own file, transitive imports, the
   extended record's own file, builtins; MemberLookup.md#visibility), so a
   file's extension view is a function of its import DAG alone and
   reordering the imports of a third file changes none of its results. The R1 rows
   ("a row on a type's scope also reads the same-named members of every
   extension of that type, in whatever file") stay as written: they
   over-approximate (an unseen extension can only turn a miss into the
   "import it" note), which is safe for invalidation.

## Phase 2: module records and the all-hit skip

**Built.** Off unless `--incremental-sema` or `KAIRO_INCR_SEMA=1` is given, with
`--cache-dir` (the compiler flag; the language server's live check is a
separate switch). Code: `Compiler/Driver/ModuleRecords.k`
(F_sema, the manifest, the check, the writer), `CompilerInstance::_incr_begin`
/ `_incr_replay` / `_incr_end` (the decision and the replay, around the
action loop of `execute`), the record bodies and header list in
`FrontendAction::_dump_incremental` and `_sema`, the object keys in
`_codegen`. Flags: [Driver.md](Driver.md#incremental-sema---incremental-sema).
Tests: `Tests/Sema/Incremental/records.k`, `Tests/CLI/Driver/incremental_sema_key.k`.

### What the hit decision compares

**The whole-input check, not `M(m)` over the dependency rows.** Phase 2 only
decides all-hit versus not, and a hit means "bit-for-bit the same inputs as
the run that wrote the records", so the simplest sound key is used and the
rows are stored for phase 3 without being evaluated. A run is a hit when,
against the manifest:

1. **F_sema** matches, part by part (so the miss names the part):
   `f.schema` (`INCR_SEMA_SCHEMA.CACHE_SCHEMA`), `f.version` (the whole
   version string, metadata included), `f.args` (the hash of the command
   line as given, every word in order but argv[0] and the observation flags
   `--incremental-sema`, `--incr-verify`, `--print-incr-status`,
   `--incr-paranoid`, `--time-passes`), `f.cwd`, `f.env` (the hash of a fixed
   list of variables that steer the sysroot, SDK, include search and colour:
   `KAIRO_SYSROOT_SHARE`, `KAIRO_SYSROOT_CACHE`, `KAIRO_CACHE_DIR`,
   `XDG_CACHE_HOME`, `HOME`, `LOCALAPPDATA` (the rest of the cache-root
   chain: without the first two, they pick the cached sysroot), `SDKROOT`,
   `DEVELOPER_DIR`, `NIX_CFLAGS_COMPILE`, `PKG_CONFIG_SYSROOT_DIR`,
   `PKG_CONFIG_LIBDIR`, `CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH`,
   `INCLUDE`, `LIB`, `XWIN`, `MSVC_CACHE`, `NO_COLOR`, `TERM`,
   `KAIRO_INCR_TEST`), `f.diag` (the error format and the colour decision).
   The whole command line is keyed rather than a list of the flags that can
   change Sema or an object: a false miss costs a run, a false hit a
   miscompile. ObjectCache's `F` is not reused: it needs the clang backend
   started, which is after the decision; every input of it is in `f.args`,
   `f.version` and the executable below.
2. **The compiler executable** (`exe` line): the same path, and the same
   content (stat, then hash). In F rather than as a file it would cost a hash
   of a 150 MB debug binary per run. `KAIRO_INCR_TEST_EXE` names a stand-in
   file for the tests.
3. **Every file the run opened** (`file` lines): every SourceManager file
   (Kairo sources, the builtin and std trees, the headers the index
   registered), hashed from the **bytes the run read** (the SM buffer), and
   every file of every header set of the graph (`HeaderSet::files`, kfid 0
   included), hashed from disk. Sorted by path, each once.
4. **The directories a resolution goes through** (`dir` lines): for each
   Kairo file, its own directory and, under every search root
   (`ImportResolver::root_dirs`), the same relative directory and each of its
   parents; each listed as the sorted names of its `.k` files and
   subdirectories (other files, an output binary in the working directory,
   do not count), or `missing`. A module file added or removed there (one
   that could shadow, collide with or, beside `foo/module.k`, change a
   resolution with no source edited) is `graph changed: <dir>`. A file added
   to or removed from the graph is therefore a miss by construction (it is an
   edit of an importer, or a listing change).
5. **The link's objects** (`obj` lines): each still the file the recording run
   linked (stat, then hash). The object store is not consulted: an object
   clang warned about is never stored (Incremental.md, deviation 1), and the
   record must not depend on it.

Stat, then hash: a file whose size and mtime equal the record's is trusted
(`--incr-paranoid` hashes every file); otherwise its content is hashed, and
equal content is a hit (a touch). A file whose mtime is within 2 s of the
recording run's start or after it is recorded with mtime 0, which is never
trusted: an edit made during the run, or in the same clock tick, would
otherwise keep the old stat and hit forever. A hit that rehashed a touched
file writes its new stat back (`ModuleRecords::refresh`).

### The records

Under `<cache-dir>/kairo-cache-v<CACHE_SCHEMA>/mod/`, beside the object
store's `<F>/objects/`:

- **The manifest**, `run-<H(input path, output path)>.txt`, text lines:
  `kairo-incr-run 1`, the F_sema parts, `t <recording start, ns>`, `exe`,
  `file`, `obj` (`<kind> <mtime> <size> <xxh3-128> <path>`), `dir <listing
  hash> <dir>`, `mod <module>\t<O keys>\t<I(m)>` per module (the module written as a JSON string when it holds a byte below 0x20 or starts with `"`), `pthread 0|1`,
  `warns <n>`, `diag <bytes>` followed by the rendered diagnostic stream and
  `end`. Named by the input and output, not by F, so a flag change is a miss
  that says so (`flags changed`) rather than `no record`.
- **One record per module**, `<H(module path)>.json`: `module`, `objects` (its
  TU's object-cache key(s)), `imports` (the Kairo files its import edges
  resolve to; header closures are left out, thousands per TU, and hashed
  whole in the manifest), `interface` and `deps` (exactly the entries
  `--dump-interface` / `--dump-deps` print for that file: `I(m)`, the macro
  hash, per declaration `DeclId`, `I`, body hash and refs, the scopes' name
  sets, the surface, name, overlay and declaration rows). What phase 3 reads;
  phase 2 reads only `I(m)` and the keys, through the manifest, for
  `--incr-verify`.

Written only by a run that finished with no error (and, linking, codegen
done): the module records first, then the manifest, each through a private
name and a rename, so a crash leaves the old manifest or the new one, never
one naming records that are not there. The dependency log is on whenever the
flag is (`SemaContext::log_deps`), so a miss always has the rows to write.

### What a hit skips, and the replay

`CompilerInstance::execute` decides once, before the action loop, after
`_plan_outputs`, include discovery, the global allocator and the Kairo
library. On a hit the Kairo input's `FrontendAction` is not created: no
load, preprocess, parse, header sets, Sema, lowering, EmitPlan, `GraphFacts`
or key fill. Its `TUResult` is the record's: the objects (in the recorded
order), `ffi_pthread`, the warning count. Everything else runs as it does:
C/C++ inputs (their own cache), the runtime, the link (which always reruns,
Incremental.md deviation 8).

**Diagnostics** (change 4, as far as phase 2 needs it): the engine buffers
every diagnostic until the end of the run, so per-file attribution is not
needed for an all-or-nothing replay. The recording run stores the console
consumer's rendering of exactly the diagnostics the action loop delivered
(`render_range` over the buffer slice, in delivery order); a hit prints that
text first (`replay`), then whatever it reports itself (pre-loop flag
warnings, the link). The warning count is added to the engine
(`DiagEngine::add_replayed`) so totals and the exit status are the recorded
run's. Byte-identical under `--error-format=basic` and `json`; under the
pretty renderer it is exact unless a diagnostic outside the slice (a link
warning) would have been coalesced with one inside it, since the pretty
renderer coalesces per line across the set. **Change 4 proper (per-file
diagnostics) is still open.** A run with an error writes no records, so
errors are never replayed.

`--incr-verify`: on a would-be hit the run proceeds in full and its
diagnostic text, warning count, object list and every module's object keys
and `I(m)` are compared with the records loaded before the run; a difference
is U001E and the records are not rewritten. A verified run then rewrites
them.

### Eligibility

A record stands for one Kairo input whose only frontend outputs are the
link's objects (or none, under `--type-check-only`). Not eligible, and so
always a full run (status `miss: not eligible (<why>)`): no `--cache-dir`;
not exactly one Kairo input, or one found through an include; a C++ input
that includes a `.k`; objects in a temporary directory; `--emit` beside the
link or of `.s`/`.ll`/`.bc`; `--print-cg`, `--print-ir`, `--force-recompile`;
any `--print-*` / `--dump-*` / `-###` word; a run stopping before Sema. C and
C++ inputs are allowed (they compile after the loop and read nothing it
writes); so are link inputs.

### Not covered (inputs the key may miss)

- **Environment variables** outside the list above (one the C++ headers'
  `__has_include` or a pkg-config call reads, `PATH`).
- **The sysroot and toolchain files outside the header sets**: headers the
  stream asks clang for at compile time (`<new>`, `<coroutine>`), the clang
  resource directory, libraries the link reads. The same as the object
  cache's deviation 12; the link reruns, so a changed library still links.
- **`-include` files** given through clang words, and **response files**
  (`@file`): the words are keyed, not the file behind them.
- **Generated files** read through a virtual buffer (`<...>` names): their
  content is a function of the keyed inputs.
- **A C++ header shadowed** by a new file in an earlier `-I` / `--cxx-include`
  directory: header directories are not listed, only the files found.
- **A new module file under a search root** in a directory that is neither
  the directory of a graph file nor one of its root-relative parents (an
  import resolves by probing exactly those, so this is believed complete for
  resolved imports).
- **The global-allocator and script clash reports** read the action's
  source ranges; a hit has none, so a link that fails on a clash reports it
  without the source position (only reachable with one input, where neither
  clash exists).

### Measured

On the compiler's own tree (382 modules, 24 threads, debug compiler, warm
object cache; a clean run into an empty cache needs about 1.8 GB of objects
and store copies, and Incremental.md's table has the clean numbers): a run
with no change and no flag takes 50.9 s (Sema 30.6 s, CacheKeys 15.3 s,
GraphFacts 4.9 s, Headers 4.8 s; 4.85 GB). With the flag on and writing the
records (a miss) it takes 54.0 s (+6 %, 5.17 GB). A hit takes 4.8 s and 1.60
GB: the four C/C++ inputs' cached compiles 1.8 s, the link 1.8 s, include
discovery 1.1 s (before the decision), the check itself under 0.1 s.
`--incr-verify` on a hit is a full run (52.7 s). The records are 18 MB (382
module records, 0.49 MB manifest). On the test fixture (three modules and
the builtins, 31 records) a miss is 325 ms and a hit 30 ms, of which the link
is 9 ms. What is left of a hit on the compiler's tree is not the frontend:
the link (deviation 8 of Incremental.md), the C/C++ inputs' cached compiles
and the include discovery that runs before the decision.

### Not built after phase 2

- Load interfaces instead of re-checking an unchanged import (serialized
  Sema facts, change 2's post-`Checked` facts). Blocked: see Phase 3.
- Per-module object reuse without the key fill: the stored O keys stand for
  the stream only when every input of the stream is unchanged, which needs
  the readers after Sema (EmitPlan, codegen) to log their reads.
- Moving include discovery after the decision when no C++ input exists.

## Phase 3: the re-check plan, and what blocks the rest

**Built:** the decision half of phase 3, behind the compiler flag
`--incremental-sema` (off unless given). **Not built:** any reuse. A run that
misses is a full run; it can say which modules HAD to be re-checked, and
prove it.

Code: `Compiler/Sema/Incremental/Plan.k` (the rules, over strings: no tree,
no Sema type), the plan records and the changed-file scan in
`Driver/ModuleRecords.k`, `CompilerInstance::_incr_plan`, the per-TU
diagnostics at the drain in `FrontendAction::_sema_finish`. Flag:
`--print-incr-plan` ([Driver.md](Driver.md#incremental-sema---incremental-sema)).
Tests: `Tests/Sema/Incremental/plan.k`, `plan_oracle.k`.

### What it does

1. **A plan record per module and manifest**, `<H(module, manifest path)>.plan`
   beside the JSON record (per manifest, so another input or output sharing
   the cache directory cannot replace the rows this one's next plan reads):
   the same interface and rows as tab-separated lines (`E` a declaration:
   id, scope, name, `I`, body hash, extended type, refs; `C` a scope's
   names; `S` surface; `N` name rows; `O` overlay rows; `D` declaration
   rows), `F` lines (the files the module's diagnostics name a position in,
   its own left out) and the module's own diagnostics as rendered text:
   what its sink delivered at the drain, by TU (an instance's diagnostics
   are in the TU that checked it). `INCR_SEMA_SCHEMA` is 3.
2. **Records are written by a run with errors too**, marked `errors 1` in
   the manifest. Such a manifest is a baseline for the next plan and never a
   hit (`miss: the recorded run had errors`): an error is still not
   replayed. A run that stopped before Sema writes nothing and the older
   records stay.
3. **The miss scan does not stop at the first changed Kairo source**: it
   collects all of them, and learns whether anything else moved. The status
   line is still the first difference.
4. **The plan** (`incr_plan`): R0 to R7 exactly as `Scripts/incr_oracle.py`
   has them, evaluated over the OLD records' rows against the diff of the
   old interfaces and this run's. Plus one rule of its own:
   - **R8** X's recorded diagnostics name a position in a file whose text
     changed. A position is in no hash (open hole 1), so no interface moves
     and the note would be replayed with a stale line. This is the decision
     on positions: re-check the reader of the position. It reaches only
     files that have a diagnostic with a label, note or fix-it in the edited
     file; its cost on a real tree was not measured.
5. **The proof** (`--incr-verify`, `incr_plan_verify`): every module the
   plan leaves out must have, in this full run, the `E` and `C` lines, macro
   hash and diagnostic text of its record. One that differs is U001E and
   the records are left alone. This is stronger than the oracle's test (it
   compares `--print-sema` and diagnostics): an unchanged interface is what
   a later reader of that module would be evaluated against.

### When there is no plan: every module is re-checked

`incremental: plan: re-check all N modules (<why>)`. These are all the
inputs the rows cannot see; each is the fallback to a full check.

| Why | What moved |
|---|---|
| `no record`, `no plan records` | first run; a record of another schema; a damaged or missing `.plan` |
| `flags changed`, `environment changed`, `f.diag changed`, `f.cwd changed`, `f.schema changed`, `compiler changed ...` | any part of F_sema, or the executable |
| `changed: <path>` of a file that is not a `.k` | a C or C++ header of a header set |
| `added: <path>`, `removed: <path>` | a recorded file appeared or went |
| `graph changed: <dir>` | a module file added or removed where a resolution goes through |
| `the set of modules changed` | an import added or removed made the graph another set of modules |
| `changed: <path> is no module of the graph` | a changed `.k` this run did not check |
| `the run stopped before Sema` (`plan: none`) | a parse error: no facts to compare |

Not eligible at all (no records, no plan): the phase 2 list.

### Measured

On the compiler's own graph (`Compiler/Driver/Kairo.k`, 383 modules, 24
threads, `--type-check-only`, debug compiler): a run with an edit costs what
a full run costs, because nothing is reused (37 to 40 s against 48.5 s with
no switch and 45.7 s writing the records; the records add 0.4 GB of resident
size). A hit takes 1.5 s and 0.25 GB. The plan's own cost (`IncrPlan`:
loading 383 records, both indexes, the rules, the proof) is 0.85 s. The
records are 31 MB (JSON and plan lines both). All four diagnostic streams
(base, off, on, hit) are byte-identical, and each edit's stream equals a run
with no switch.

What the plan says would have been enough:

| Edit | Re-check set | Proof |
|---|---|---|
| body of `shell_quote` | 1 of 383 | verified, 382 as recorded |
| a defaulted parameter on `IdentifierToken::as_string` | 2 of 383 | verified, 381 |
| a defaulted parameter on `SourceManager::get_filename` | 110 of 383 | verified, 273 |

The six edits of `Inputs/self_edits.json` on the compiler's own tree
(`incr_oracle.py --compiler-plan`, 15 min on the debug compiler): the
compiler's set equals the oracle's on each (1, 2, 2, 1, 12, 1) and each
proof passes.

`Tests/Sema/Incremental/Inputs/proj`: the compiler's set equals the
oracle's on all 44 scenarios and its proof passes on each
(`plan_oracle.k`). `Inputs/plan` (`plan.k`): a body, a signature, a private
field's type, a generic body, a declaration added and removed, a line shift
under another file's note (R8), a header, a flag, a file added, each
compared with a run that has no switch; and a record with rows removed,
which the proof catches.

### What blocks the rest of phase 3

"A changed file's imports are loaded, not re-checked" cannot be built on
what exists, for three reasons, each read from the code:

1. **A record holds hashes, not values.** `I(decl)` is a hash of the
   signature, the structural types and the solved panic set. Nothing in a
   record can rebuild a declaration with its canonical types, its symbol
   tables, its overlay or its redeclaration ring.
2. **The only stored tree is the parsed one.** [Serialization.md](Serialization.md)
   writes no slot a later stage fills and fails on a tree that holds a
   canonical type; its "What the Sema section needs" (canonical types,
   cross-file node identity, the nodes Sema adds) is not started. Without
   it a file that re-checks has nothing to bind against: its
   `resolved_decl`s point into its imports' checked trees (finding 3), and
   its lowerings read their lowered ones (finding 4).
3. **The imported C++ is not in any record at all.** Rows into a header's
   scopes are dropped, a foreign declaration is a pointer into a live clang
   AST, and almost every file of the compiler imports one.

**The floor of any process-per-run design.** Measured with the base release
compiler on the kals graph (420 files, one run of 10.8 s): before the first
TU's Sema starts, Preprocess is 0.62 s, Parse 0.19 s and Headers 3.33 s
(waiting for the header-set build 2.32 s, indexing it 0.99 s): 4.1 s. A
fresh process that must have its imports' declarations live pays that, and
then Imports (1.79 s of work) and type resolution (0.57 s) for every file,
before it checks one body. So, without the on-disk C++ preamble described
further down (not built; it would take out the 2.3 s wait), no batch-shaped
phase 3 brings a kals body edit under the 4.1 s measured plus those passes
(about 5 s, the second part an estimate), against the 150 ms target: the
edit is cheap only in a process that stays up (phases 4 and 5).

**The smallest sound alternative, not built.** Under `--type-check-only`
only (facts after `Checked` are in no hash), a file the plan leaves out
could be checked with the bodies of its plain functions emptied: not
generic, not in a generic owner, not `inline` / `eval` / `const`, a written
return type, an empty solved panic set, no `yield`, no nested declaration,
no constructor. By the log's own claim nothing reads such a body. Its sink
is dropped and its recorded diagnostics stand. That removes most of
ExprTyper (7.1 s of work on that run) and ChainBinding (4.2 s) for
unchanged files and none of the 4.1 s floor: an estimate of about 5 s from
10.8 s, not measured. It needs: the decision made per import group as Sema
reaches it (the plan here is computed after the run); the skimmed file's
`I` compared with its record afterwards, with a restart when it differs;
and hole 2 closed or made a fallback, because a skimmed first namer hands
its instances' diagnostics to the next file that names them. It was not
built: it is a different thing from phase 3, it is thrown away by phase 4,
and it does not reach the target.

### Holes and limits of the plan

- **Hole 2 is visible to the proof.** If an edit makes the first namer of
  an instance stop naming it, the instance's diagnostics move to a module
  the plan leaves out, and `--incr-verify` reports that module. No test
  reaches it (it needs a diagnostic inside an instance).
- **Two files with one module path** share a record name, as in phase 2.
- **A diagnostic the driver reports outside a TU's drain** (the global
  allocator clash) belongs to no module's text.
- **Parallel Sema:** a diagnostic another thread sends straight to the
  engine during a drain would be counted into that TU's text. None does
  today (fronts write their own sinks).
- **R8 reads rendered positions only through the diagnostic's own
  locations** (location, labels, fix-its, notes); a file named only inside
  message text is not seen.
- The plan is evaluated after the run, over all modules at once. Deciding
  per import group, in import order, as a reusing run must, is not built;
  the rules are order-free except R5 and R6, which are a fixed point.

## Phase 4: the live check, at full fallback

**Built:** the API a process that stays up calls, its test mode and its
oracle. With `in_place` off every `replace_file` is a full check in a new
`CompilerInstance` inside the same process: the fallback the design keeps for
what cannot be retracted soundly (next section).

Code: `Compiler/Tooling/LiveCheck.k` (`LiveCheck::check`, `replace_file`,
`set_overlay`, `file_diags`, `flush`; `mode` and `why` say what a step
did), `Compiler/Diagnostic/FileDiagnostics.k` (`FileDiagConsumer`: every
diagnostic as an object with the file whose drain delivered it; the driver
names the file around each drain through `FrontendOptions::file_diags`),
`Compiler/Tooling/IncrReplay.k` (`--incr-replay=<script>`,
`--incr-replay-dump=<dir>`), `Scripts/incr_replay_check.py` (the oracle).
Tests: `Tests/Sema/Incremental/replay.k`, `replay_scenarios.k`.

The oracle is strict: per step, a fresh `kairo --type-check-only
--dump-interface` on the same paths; stderr must be byte-identical and the
interface dump equal. Nothing is normalized.

### Measured (debug compiler)

| | |
|---|---|
| `Inputs/plan`, 15 steps (38 files) | each step equal to a clean run; about 0.29 s a step |
| `Inputs/proj`, the 44 scenarios and their reversals, 89 checks in one process | each equal to a clean run |
| the compiler's graph (383 files), first check | 27 s, 3.76 GB resident |
| the same, each later step (a full check in a new instance) | 25 to 45 s |
| resident size per step, compiler's graph | 3.76, 4.30, 4.85 GB: **+0.54 GB a step** |
| resident size per step, `Inputs/plan` | 428 MB to 665 MB over 14 steps: +17 MB a step |

**A destroyed `CompilerInstance` does not give back everything it took.**
Releasing the header sets, every file from Lexing on and the retained
diagnostics before the destroy changed nothing (4.30 and 4.84 GB). What
holds the 0.54 GB was not found; a process-per-run never saw it. A live
process on full fallback grows without bound, so the fallback is correct
and is not a way to stay up.

### Re-checking in place: the refresh set

**Built**, opt-in: `LiveCheck::in_place`,
`--incr-replay-in-place`. Off, every `replace_file` is the full check above.

The unit is coarse and sound, and does not need stable declaration
addresses (change 3): on an edit of F the **refresh set** is F and every
file that imports F, however far, with every member of an import cycle that
holds one. Files outside it are kept untouched: trees, canonical types,
lowered state, diagnostics, the loaded C++ header sets. Nothing kept names a
declaration of a refreshed file by address (a file that could is an importer
and is in the set), except through the build-wide stores, which are purged.
The plan (R0 to R8) is then an optimisation for later: it would shrink the
set to the readers; it is not needed for soundness.

Steps of `LiveCheck::_refresh` (`Compiler/Tooling/LiveCheck.k`):

1. The set: `transitive_importers(F)`, then closed under
   `FrontendAction::refresh_extends`: a file whose record a set file
   `extend`s sees the extension without importing it (MemberLookup's
   visibility), so it joins with its importers.
2. Refusals (`refresh_blocker` and the checks beside it), each a full check
   with the reason in `LiveCheck::why`: see the table below.
3. `retract_instances` (`Sema/Incremental/Retract.k`), while the old trees
   can still say whose a declaration is:
   - a registry entry that names a declaration of the set (primary, pattern,
     explicit specialization, a record in its arguments, or another such
     instance) is **dropped** (`InstantiationRegistry::drop_entries`);
   - an entry of kept declarations stays at its address and is **re-armed**
     when the use that made it live is in the set (`liveness` back to Minted, `depth` 0,
     once-only reports armed), except an imported C++ template's shell;
   - `ForeignRegistry`: USRs of things imported into dropped shells are
     forgotten; the C++ stand-in of a set record is **orphaned**, and the
     re-read record adopts it (`adopt`, `TypeExport::_ours`).
4. `DiagEngine::begin_recheck`: the duplicate filter, the counts and the
   poison scopes of the set's files are forgotten; the files' entries leave
   the per-file diagnostic list.
5. `detach_for_refresh` per file, importers first: the context leaves the
   table and **stays allocated** (`CompilerInstance::retired`), tokens,
   walked mark and macros are dropped, the bytes re-read. Not destroyed:
   address-keyed stores (canonical types, the registry) would meet a reused
   address.
6. `preprocess_one`, then every hoisted table (`index_one`), then
   `parse_one` per file.
7. `FrontendAction::refresh`: the header set of each file joined and its ffi
   imports stamped, the prelude import, the visibility stamp, the set's
   import groups in import order on one thread with their own effect table
   and mint ranks (after every rank of the first check); new interface
   facts replace the old.
   Steps 5 to 7 are `LiveCheck::_recheck`, which the second tier runs too
   (below); `_snapshot` records each file's header set, import edges and
   module path before step 4; when any changed by step 6, the edit is a
   full check instead of step 7.
8. After Sema, two things that make the result one a fresh run would not
   print, each turning the step into a full check: an instance's first use
   moved across the set's border (below), or an adopted stand-in's record
   has another interface hash (its layout) than before.

`early_release` of header sets is off in a live instance.

**An instance's once-only reports belong to its first use in check order**
(its bounds, a failed conformance: reported where it became live, once per
build). A re-check of some files can move that without re-checking the file
it moves to: a re-armed entry that nothing of the re-check made live again
(the set stopped using it; a kept file is now first), or a set file using a
kept file's live entry from earlier in the order
(`InstantiationRegistry::relive_log`, `note_reuse`). Both are detected and
are full checks. `Tests/Sema/Incremental/replay_instances.k` has both.

#### Full check instead (every case, with `LiveCheck::why`)

| Why | When |
|---|---|
| `the first check` | |
| `re-checking in place is not built` | `in_place` is off |
| `the pretty renderer coalesces across files` | not `--error-format=basic` / `json` |
| `--prelude or --force-include` | either flag is given |
| `not a checked file of the graph` | a new file, a removed file, a file that failed before Sema |
| `a C or C++ header` | the file is a header of a header set |
| `a builtin file` | the set holds a file under the builtin root (lang items) |
| `a file that declares a specialization: <file>` | an explicit or partial specialization in the set: the registry's tables match every use in the build |
| `a file that defines another file's member out of line: <file>` | the definition is spliced into a kept file's redeclaration ring |
| `a diagnostic from before Sema` | a file of the set has, or its re-parse produces, a preprocessor or parser diagnostic: it has no owning drain |
| `a diagnostic from inside an instance` | a set file owns a diagnostic located outside the set |
| `an import was added or removed` | a set file's Kairo imports changed, or one does not resolve |
| `a file could not be re-read`, `the preprocessor refused a file`, `a file did not parse` | |
| `an instance the edited files used first is now used first by a kept file` | see above |
| `the edited files now use an instance before the kept file that used it first` | see above |
| `a record handed to a C++ template changed its layout: <DeclId>` | an adopted stand-in whose record's `I` moved |
| `a C or C++ import was added or removed` | a set file's header list is another header set |
| `a C++ template instance was first filled for an edited file` | only with `strict_cxx` |

How often: on the compiler's own graph, trailing-comment edits of ten files
drawn at random, re-run under the oracle, all refreshed in place (the C++
shell case and the extension rule are what kept others on the full path).

#### Measured

Debug compiler, `Compiler/Driver/Kairo.k` (389 files), a full check 28.0 s;
every row equal to a fresh run under `incr_replay_check.py` (stderr and
`--dump-interface`). An in-place re-check of a leaf (`Support/ShellQuote.k`,
refresh set 13) takes 2.9 s, of the entry (set 1) 0.36 s, of
`Sema/Check/BaseInitCheck.k` (15) 3.3 s, of `AST/OperatorFacts.k` (103) 14.3
s, of a core file (`Location/SourceManager.k`, 228) 27.4 s: a core file
degrades to a full check's time, as designed. Release numbers are below.

A leaf's set is 13 and not 1 because `Driver/*.k` files `extend
CompilerInstance`: the extended record's file and its importers join.

**What grows.** Until the replaced trees are freed (Memory, below), a
refresh keeps the set's old contexts, dropped registry entries (the registry's arena), the replaced diagnostics
(the engine's) and the stand-ins in the clang AST: about 8 MB per
refreshed file on this graph (0.1 GB for a 13-file set, 1.1 GB for a
228-file one). Small fixtures: `Inputs/plan` 15 steps 434 to 494 MB,
of which the four full steps are most.

#### Release numbers

Release compiler, same oracle. A full check is 7.2 s on
`Compiler/Driver/Kairo.k` and 7.7 s on `Analyzer/Driver/kals.k`. Resident
size on the kals graph: 4.11 GB after the first check; 20 more edits of
`TextUtil.k` (19 files each) add about 84 MB each, 1.6 GB in all. Every edit
measured gives a result equal to a fresh run, on both graphs:

| Graph | Edit | Refresh set | In place | Full |
|---|---|---|---|---|
| Kairo.k (389) | entry | 1 | 0.12 s | 7.3 s |
| | `Support/ShellQuote.k` | 13 | 0.50 s | |
| | `Sema/Check/BaseInitCheck.k` | 15 | 0.58 s | |
| | `AST/Printer/ASTPrinter.k` | 19 | 0.71 s | |
| | `AST/OperatorFacts.k` | 103 | 2.71 s | |
| | `Interop/Clang/ClangLocMap.k` | 136 | 3.56 s | |
| | `AST/Kind/ExprKind.k` | 207 | 4.81 s | |
| | `Location/SourceManager.k` | 228 | 5.35 s | |
| | leaf body, error, fix | 13 each | 0.54 to 0.56 s | |
| kals.k (423) | entry | 1 | 0.13 s | 8.6 s |
| | `Analyzer/Index/Worker.k` | 2 | 0.17 s | |
| | `Analyzer/Tuning.k` | 21 | 0.61 s | |
| | `Analyzer/Server/TextUtil.k` | 19 | 0.65 s | |
| | `Analyzer/Json.k` | 34 | 0.89 s | |
| | `Compiler/Support/ShellQuote.k` | 12 | 0.59 s | |
| | `Compiler/AST/Kind/ExprKind.k` | 235 | 5.90 s | |
| | `Compiler/Location/SourceManager.k` | 256 | 6.65 s | |

#### Hidden friends of C++ template instances

A hidden friend (an `operator==` written in a C++ class template) is written
in the class but is an entity of the namespace. Each Kairo instance of one
specialization imports its own members typed by its own arguments (a variant
fill, `DeclImport::fill_usr`), so `DeclImport::_in_fill_spec` follows the
lexical context as well as the semantic one and a variant fill mints its own
friend. Otherwise the second instance's fill would find the first one's
friend in the registry and re-type it with the second instance's arguments,
and the result of a plain run would depend on check order (`Box<usize>` and
`Box<u64>` are one specialization to clang). Test:
`Tests/Sema/FFI/hidden_friend_variants.k` (reduced from `Inputs/hidden_friend`).
The retraction of a dropped function-template instance does not drop the
template's own declaration (which its entry holds) among the dead nodes,
which would drop every instance of `std::move`, `std::construct_at` and the
like and forget their USRs.

`LiveCheck::strict_cxx` is a flag; nothing measured needs it. Whether a
fill's own clang diagnostics are lost on a re-check of the file that
demanded it is unproven (below).

`KAIRO_LIVE_DEBUG=1` prints every USR the retraction forgets.

#### Not proven

- **A C++ template's fill reports through the TU that demanded it**, once
  (clang's diagnostics for the instantiation). When that TU is refreshed
  and the shell is kept, the report is not repeated. A diagnostic located in
  a header is caught (`a diagnostic from inside an instance`); one located
  in the set file is not. No test has a failing C++ instantiation.
- **Conformance rows, tuple records, nullable layouts and default-argument
  thunks** homed in a retired context are not purged; nothing in the three
  projects or the compiler's graph reads one wrongly under the oracle, and
  no walk asserts it (the debug self-check over kept structures is not
  built).
- The oracle compares diagnostics and interface dumps; `--print-sema` of a
  refreshed file is not compared.
- Parallel Sema is not used by a refresh (one thread, in import order).

## Phase 5: buffers, the observer, two tiers, and the worker that stays up

**Built**, behind `initializationOptions.liveCheck` in kals (on by default;
`KALS_LIVE_CHECK=0` turns it off) and `LiveCheck::two_tier` /
`--incr-replay-two-tier` in the compiler (the compiler flag
`--incremental-sema` is a separate switch, off unless given). The server side is [LanguageServer.md](LanguageServer.md)
section 10, "The live index worker".

### Buffers

`LiveCheck::set_overlay` / `clear_overlay` are honoured by a refresh.
`SourceManager::replace_bytes` (`VirtualFileManager::replace_bytes`) gives a
file id a caller-owned buffer in place: a mapped file gives up its mapping, a
buffer changes its view, and the segment gets a RESERVED range with slack the
first time, so a keystroke does not take new address space. `LiveCheck` keeps
one heap string per overlay (its bytes never move) and swaps it at the detach;
the old text is freed after the swap. A cleared overlay becomes this object's
copy of the disk's text (a file that was a buffer cannot go back to a mapping
without a new file id). An importer whose text did not change keeps its bytes.

On the FULL path a buffer is staged (`SourceManager::stage_overlay`) and given
to the file where the graph first loads it. `load_overlay` mints the file id
at once, ahead of every file loaded after it, and diagnostics would then come
in another order than a fresh run's (`Inputs/plan`, the header step).

Oracle: `incr_replay_check.py --overlay` (`--incr-replay-overlay`): every edit
of an existing `.k` file reaches the live side as a buffer and the disk keeps
the old text; the clean side applies the edits to the disk.
`Tests/Sema/Incremental/replay_overlay.k`.

### The observer

`LiveCheck::observer` (a `Tooling::SemaObserver`) is installed in every new
instance: `on_checked` / `on_lowered` for every file on a full check, for
exactly the re-checked files on a refresh (`LiveCheck::rechecked`). A refresh
that turns into a full check has called it for its set first: a host reads
`mode` before it uses what it collected. `--incr-replay-observe` prints the
calls; `Tests/Sema/Incremental/replay_observer.k`.

### Two tiers

`LiveCheck::two_tier` (with `in_place`). An edit of F is two things.

1. **`replace_file(F)`, the first tier.** The refresh set S is computed and
   every refusal known before anything is touched is made (`_plan`, as one
   refresh does). The whole of S leaves the build-wide stores AT ONCE
   (`FrontendAction::retract`: the registry's drops and re-arms, the foreign
   registry). S joins the queue, which is kept in the order the sema loop
   runs GROUPS (`FrontendAction::group_order_of`: `ImportGroups` over the
   import order, each import cycle's members together and after every group
   it imports; the plain import order breaks a cycle at one file and puts it
   before files outside the cycle that it imports, which made the first
   queued step 93 to 203 files). Then F is re-checked,
   with the queued files F imports before it (`_tier_redo`, through
   `_recheck`): forget their
   diagnostics, detach, re-read, preprocess, index, parse, the import and
   header checks, `FrontendAction::refresh` for that group.
2. **`drain(max_files, prefer)`, the second tier.** The next queued file,
   which is one file or one import cycle (or, with `prefer`, the first queued
   file of what a preferred file imports: one step towards it), the same
   way; until `max_files` are done or the queue is empty. A new `replace_file` between two `drain`s is an edit that
   pre-empts: its first tier runs, and its set joins the queue.

**The rule.** A file is re-checked only when no file it imports, however far,
is queued. So the foreground set of an edit of X is X plus the queued files X
imports (transitively; an import cycle is therefore always re-checked
whole). Everything X's Sema reads is then kept (outside every refresh set) or
already re-checked. A queued file still holds its old tree, which points at
the replaced declarations of what it imports; nothing reads that tree until
its own turn, and at its turn it is detached, not read.

What was checked for that claim:

- **Sema reads other files' trees through its imports only, with one
  exception**, `MemberLookup::index_extensions`, which walks every context of
  the build. A queued file E's `extend R` is keyed by R's OLD declaration (if
  R's file was re-read) and is not found by the new one; in a fresh run E is
  checked after R's file, its target is not resolved yet, and it is not found
  either. An extension of a non-record type (`extend i32`) in a queued file
  that X does not import is hidden from X in both, but through another list:
  the old tree's is resolved (`_hidden_by_type`), a fresh run's is not yet
  when the file comes later in the order (`_hidden_unresolved`). Both feed
  only the "import it to use it" note of a failed lookup, whose wording
  through the two paths is NOT compared (see "Not proven").
- **The registry.** Dropping and re-arming for the whole of S up front is what
  one refresh does; a queued file's old tree holds pointers to dropped entries,
  which stay allocated and are never read.
- **What one refresh decides at its END is decided across the slices**
  (`FrontendAction::tiered`): a re-armed entry must be used again by a file of
  the retraction that re-armed it (made live from one, or used while live from
  one: the relive log), judged when the queue empties (`tier_finish`); an entry
  a later retraction dropped is excused. An adopted stand-in's layout is
  compared with the hashes from before the first retraction since the queue
  was last empty, whichever slice re-reads the record. "A file uses an
  instance before the kept file that used it first" is judged per slice, as
  before. `--dump-interface` is written when the queue empties.
- A queued file's diagnostics stay in the per-file list until its turn; one
  located in a file re-read since may hold a stale position, which a host
  never re-renders (kals keeps the rendered rows) and `_plan` reads as "not in
  the set" (a full check, never a wrong answer).

**Shapes that do not get a one-file first tier**, and how often, on this
repository's two graphs:

| Shape | First tier | Here |
|---|---|---|
| a file of an import cycle | the whole cycle | four cycles, 61 of the kals graph's 426 files: the AST node files (24: `Expressions.k`, `Types.k`, `Declarations.k`, `InstantiationRegistry.k`, ...), `Analyzer/Server/*.k` (19, 0.55 to 0.7 s), `Analyzer/Index/*.k` (10), `Driver/Compiler*.k` with `FrontendAction.k` (8, 0.4 to 0.5 s) |
| a file edited while files it imports are queued | those files first | by construction rare: the user edited a file and then one that imports it within the drain (0.4 to 0.5 s for 8 files measured) |
| the entry edited while everything is queued | everything queued | the drain's time |
| a file re-checked ahead of the queue's order that uses an instance before the file that used it first | a full check (caught by the existing check; correct, 8 s) | 1 of the 3 out-of-order first tiers in the scripts: `FrontendAction.k` edited 25 files into `SourceManager.k`'s queue of 227. The other two (a leaf edited 40 and 60 files into a core file's queue) were not |
| every other refusal of one refresh (the table above) | a full check | none in the 20 scripted steps below |

No shape takes the one-batch refresh: the queue IS the batch, in the same
order, cut in time. An EDIT can put a file ahead of that order (its first
tier), and so can a preference, which keeps first uses first ("Preferred
order").

**The oracle, extended** (`incr_replay_check.py --two-tier`,
`--incr-replay-two-tier`; `drain <n>` in a script re-checks n queued files
before the step's next edit). Per step: (i) the LAST edit's first tier
reported, for the edited file, the diagnostics a fresh run reports there
(primary lines located in the file); (ii) once the queue is empty, stderr and
`--dump-interface` equal a fresh run's, byte for byte.
`Tests/Sema/Incremental/replay_two_tier.k`: `Inputs/tier.replay` (a breaking
signature and its fix, an edit pre-empting a half-drained queue, two files
alternating, an edit of a file that is itself queued, the entry edited with
everything queued), `plan.replay`, `live.replay` (first uses that move),
`cxx.replay` (layouts handed to C++), and the 44 `proj` scenarios with their
reversals, all with `--overlay`.

#### Measured

Release compiler, every row equal to a fresh run on both counts (`python3
Scripts/incr_replay_check.py --kairo <kairo> --root . --entry <entry>
--flags-file <the entry's args> --flag=--incr-replay-in-place --two-tier
--overlay --restore --rss --script <script>`). On the kals graph
(`Analyzer/Driver/kals.k`, 426 files, full check 8.3 to 8.7 s): an edit of
`Analyzer/Tuning.k` has its first tier in 68 to 73 ms (1 file) and drains 22
queued files after 0.6 to 0.7 s; `Analyzer/Server/TextUtil.k`, in the 19-file
cycle, 0.55 s (19 files); `Compiler/Support/ShellQuote.k` 71 to 76 ms and
0.57 s (13 queued); `Compiler/Location/SourceManager.k` 116 ms, 258 queued,
drained after 6.3 s. On the compiler graph (`Compiler/Driver/Kairo.k`, 389
files, full check 8.0 s): the first tier of a leaf is 73 to 150 ms and its
set drains in 0.6 to 0.7 s (12 to 18 files queued), 102 queued files in 2.8
s, 227 in 6.1 s. Edits that pre-empt a half-drained queue land mid-queue (213
and 146 files left), and one of them takes the full check of the shapes
table. 20 edit steps, 0 differences.

A core file's first tier is cheap because the importer closure walks the
graph's edges once (5 ms), name tests use a map, and the foreign registry's
215,000 USR strings are read as views, not copied (0.1 s for the retraction,
of which 86 ms is the walk of those entries). `KAIRO_LIVE_DEBUG=1` prints
the phases.

### Memory: replaced trees are freed when the queue empties

**Built** (`LiveCheck::_release_retired`). Until the queue is
empty a replaced tree is kept (`CompilerInstance::retired`): a queued file's
old tree points into the trees of what it imports and is read by the next
edit's `_plan`. When the last queued file is re-checked and `tier_finish`
(or a one-batch `refresh`) has accepted the result, every replaced tree is
freed, after its addresses are out of the build-wide stores.

**Where the memory was** (debug compiler, kals graph, 20 edits of
`Analyzer/Tuning.k`, 23 trees replaced per edit, heap in use +103 MB per
edit; measured with the allocator's own page walk, `kairo::heap_census`,
and by releasing the replaced trees stage by stage):

| What | Per edit (23 trees) | How it was found |
|---|---|---|
| heap blocks owned by the trees' preprocessing/index-stage objects (the `TranslationUnit`, the hoisted `DisambigTable`, import edges, macro records: `ASTContext::_cleanup_pp` / `_cleanup_index`) | 54.2 MB | released by `release_from(Preprocessing)` alone |
| the trees' arena blocks (all seven arenas; capacity) | 42 to 48 MB | handed to the arena recycler by the destroy |
| of which AST nodes actually allocated (`ast_alloc`, what `retired_bytes` reported) | 25.9 MB | `ArenaAllocator::profile` |
| of which the pp arena | 2.6 MB | |
| heap owned by AST-stage objects (`_cleanup_ast`) | 0.37 MB | released by `release_from(Parsing)` |
| the sema arena, sema-stage objects | 0 | |
| everything build-wide together: canonical nodes and dropped registry entries left in their arenas, diagnostics, interface facts, clang stand-ins | 1.1 MB | the slope of heap-in-use over 20 edits with the trees freed |
| allocator fragmentation | none measurable | resident size follows heap-in-use (+105 against +103 MB) |

So `retired_bytes` (the AST arenas' requested bytes) was a quarter of it in a
debug compiler and a sixth in a release one; the rest was the same trees'
other arenas, their blocks' unused capacity and the heap their index-stage
objects own. Nothing outside the trees mattered.

**The sweep** (`FrontendAction::sweep_retired`, with the trees' arena block
ranges, `kairo::AddrRanges`):

| Store | Why | What the sweep does |
|---|---|---|
| canonical type table (`CanonicalTypeStore::sweep`) | a record type is keyed by its declaration's ADDRESS; so are a generic parameter (its owner), an associated type, a value argument, an array extent expression. A new declaration on a freed address would be handed the old canonical | every canonical naming an address of a dead tree (or a dropped instance's node), and every canonical built from one, leaves the table and `_pending_nullables`; the nodes stay in the store's arena with those fields cleared |
| conformance rows (`InstantiationRegistry::sweep_dead`: `_rows`, `_rows_by_conformer`, `_declared`, each kept entry's `rows`) | a row holds the implementing declarations; `_declared` is keyed by the declaring declaration's address | rows naming a dead declaration, a swept canonical, or another such row are removed and cleared; `_declared` keys in a dead tree are erased |
| dropped registry entries and their nodes | stay in the registry's arena, pointing into the trees | pointer fields cleared; a kept shell's `fill_reqs` no longer lists a dropped entry (`drop_entries`) |
| instantiation registry entries, foreign registry | purged by the retraction (phase 4) | checked by `verify_retired` before the free |

The conformance rows of a file that is re-read also leave the tables **at
the retraction** (`FrontendAction::_retract_rows`). That is independent of
the free: otherwise `extend i32 impl Named` in an edited file leaves its row
in the table, the re-check is answered from the old text, and a witness
renamed away still conforms (`Tests/Sema/Incremental/replay_free.k`, step
`witness_renamed`).

**Proof.**

- The oracle with the free on (the default): all four fixtures' two-tier
  scripts, the 44 `proj` scenarios with reversals, and `Inputs/free.replay`
  (`replay_free.k`: `Box<Point>`, `Point?`, `[Point]` of a re-read record, a
  default argument, `extend i32 impl Named` with its witness changed,
  renamed and restored), two-tier and one-batch: every step equal. A freed
  arena block is handed out again by the next step (the arena recycler), so
  new declarations do land on old addresses.
- **Use-after-free check: `KAIRO_LIVE_POISON=1`.** The replaced trees are
  not freed: their destructors run, every arena block is overwritten with
  `0xDD` and kept (`ASTContext::quarantine`), so their addresses are never
  reused and whatever still reads one reads no address. The same scripts
  under the oracle in that mode: every step equal
  (`replay_free.k`). AddressSanitizer and valgrind are not usable here:
  the runtime's heap (mimalloc, statically overriding `malloc`) is called
  directly by Kairo code, which neither sees.
- **Heap scan** (`KAIRO_LIVE_POISON=1 KAIRO_LIVE_DEBUG=1`,
  `kairo::heap_scan_report`): every word of every live heap block that
  holds an address inside a freed tree's arena block, with the block that
  holds it and a path of holders. It is conservative and NOT clean: what it
  still reports is spare capacity of strings and vectors and blocks freed
  and handed out again that were not written over (a 32-byte string buffer
  holding a 21-character name and, behind it, the last owner's pointer).
  It found what the sweep now covers (canonical nodes, a retired context's
  cleanup lists) and it is how a new holder would be found; it is a
  worklist, not a gate. On the kals graph: 1,100 to 3,200 words per edit,
  falling from edit to edit (stale bytes being overwritten), none in a kept
  tree's arena or the canonical arena among the 60 listed per scan. One
  shape was looked at in a debugger: a 128-byte block of 32-byte records
  `{object, destroy function}`, a context's cleanup list, whose last
  record named a freed tree and whose others named a live one. A cleanup
  list only ever holds objects of its own context's arenas, so a record
  naming another tree is not a live entry: the buffer is a freed list's,
  handed out again, and the record is past the new list's size. The list's
  size itself was not read (the hit did not come back in seven more runs).
- `KAIRO_LIVE_KEEP_RETIRED=1` keeps the trees as before, to rule the free
  out when something looks wrong.

**Measured after** (debug compiler, same script): resident 4340 MB after the
first edit, 4430 MB after the 20th; from the 5th edit on +0.7 MB resident
and +1.2 MB heap-in-use per edit (+105 MB with the trees kept). What still grows is the
build-wide row of the table above.

**Release numbers** (kals graph, resident size after each step, replay
driver with `--rss`): the first check is 4.13 to 4.15 GB. After the ten edit
steps of `self_tier_kals.replay` (two of `SourceManager.k`) it is 5.63 GB,
every step `ok` (7.8 GB with the trees kept). Four edits of `SourceManager.k`
in a row (259 trees each) give 5.33, 5.53, 5.85, 5.99 GB (+0.14 to 0.32 GB
each; +1.38 GB each with the trees kept), and the heap in use after each
free is 3.93, 4.13, 4.31, 4.46 GB: **+150 to 200 MB held per edit of a core
file**. The live worker, 50 edits of `Tuning.k` after the bench's 12 edits
(`live_bench.py --rss-edits 50`): 6.320 to 6.346 GB (+0.5 MB each), all
`refresh`; 200 edits from a fresh worker (`--rss-edits 200`): 4.488 to 4.772
GB (+1.4 MB each), all `refresh`, no restart (a restart about every 36 edits
with the trees kept).

**What still grows, and it is not the trees.** Measured: a leaf's edit
drops about 20 instances and holds 1.2 MB more afterwards; an edit of
`SourceManager.k` drops 2,599 (10,256 canonical types swept, 39,528 USRs
forgotten) and holds 150 to 200 MB more. INFERRED from those two points
(both about 60 to 65 KB per dropped instance) and from the code, not
measured by category: most of the dropped instances are C++ template
shells over a re-read record (`std::vector<SourceLocation>`); the re-check
fills each again, and a fill's member declarations go into the header
file's own tree (`ForeignInstantiate::_fill_in`), which is kept and
arena-allocated, beside the old fill's. They cannot be freed one by one
(an arena), and are not found again (their USRs are forgotten). The census
by block size after a core edit would confirm or refute it; not done. Bounded
only by the host's restart, which is about 11 to 15 edits of a core file
away, and hundreds of leaf edits. Reusing a dropped
shell's fill when the re-read record's layout is unchanged would remove it;
not built. After a free of 64 MB or more the allocator is asked to return
its free pages (`kairo::heap_trim`); the resident size still settles about
1.2 GB above the first check after the first core edit, pages the later
edits reuse.

Not freed, and why: canonical nodes and registry entries that were taken out
(their arenas are one block list each; they are unreachable and small);
replaced diagnostics (the engine's); clang stand-ins of re-read records
(adopted by the new record, or orphaned in the clang AST, which is never
shrunk).

**What a destroyed instance keeps (the 0.54 GB of the full path): it is
held, not fragmentation.** With the allocator's own count (debug compiler,
kals graph, three full checks in one process): heap in use 3552 MB before
the instance is destroyed, **650 MB after**; 4127 and 1217; 4694 and 1783.
So each full check leaves 570 to 610 MB of blocks that nothing frees. By
block size, per instance: 167 to 181 MB in 20 KiB blocks (8,500 to 9,300 of
them: the size of an arena's first block), 86 MB in 2,560-byte blocks
(35,215, the same count each time), 68 MB in 10 KiB blocks (7,000), 38 MB in
32-byte blocks (1.24 million), 33 to 37 MB in 1 MiB arena blocks (31 to 35),
27 MB in 128 KiB blocks (213), 15 MB in 16-byte blocks (1.0 million). The
holder was not identified: `GlobalDisambigTable` is destroyed with the
instance and destroys every context it lists, and a re-check's replaced
trees do give their blocks back when destroyed, so these arenas belong to
something else (about 2,300 owners of four arenas, or 9,000 of one). The syntax worker's 0.4 MB per one-file instance is the same shape, a
per-instance leak of live blocks and not allocator retention; whether it is
the same owner needs the same census on that worker (not done).
`KAIRO_LIVE_DEBUG=1` prints the census after every destroyed instance.

### The self-check

`KAIRO_LIVE_DEBUG=1`: when every file of a re-check is done, before the
free, `verify_retired` (`Sema/Incremental/Retract.k`) walks the
instantiation registry and the foreign registry and reports every entry that
names a declaration of a REPLACED tree. 0 in every run so far. The stores it
did not walk (canonical types, conformance rows) are now swept by address
range, and the line `[live] N replaced trees freed (...); swept ...` says how
many of each went; tuple records, nullable layouts and default-argument
thunks hold nothing of a re-read file that the scan or the poisoned runs
have shown (a tuple record is the builtin root's; a `T?` of a dead record is
swept with it; a thunk lives in the tree of the file that minted it, which
imports the callee's file and is re-read with it).

### Preferred order (open buffers first)

`LiveCheck::drain(max_files, prefer)` re-checks towards the first queued
file `prefer` names: that file and the queued files it imports, in Sema's
order among themselves, ahead of queued files it does not import. kals
passes the editor's open buffers (`LIVE_PREFER_OPEN`, on).

The hazard was the one of an out-of-order first tier: an instance's
once-only reports belong to its first use in Sema's order, and a file
re-checked ahead of the file that used the instance first becomes its first
user. The live check saw that afterwards ("the edited files now use an
instance before the kept file that used it first") and took a whole check.

The order is kept instead (`FrontendAction::prefer_first_users`):

- every retraction records, for each Kairo instance it drops or re-arms,
  the primary and the file of its first use (`RetractStats::first_*`);
- a queued file's OLD tree is still attached and its text is unchanged, so
  its dependency log (`DepLog::bodies`) names the primaries it will ask
  instances of;
- the files that go ahead are the preferred file, its queued imports, and
  every queued file that was the first user of an instance of a primary
  they name (with ITS queued imports), to a fixpoint;
- when such an instance has no first user any more (it was re-armed and is
  not live again, or it was dropped and the edited file that used it first
  no longer asks for its primary), which file is next is not known: the
  preference is dropped for that step and the queue's own order stands.

By primary, not by instance, so more files may go first than needed, never
fewer, with one approximation (an edited file that still names another
instance of the same primary is taken to name this one). The checks at the
end of each slice and at `tier_finish` are unchanged and judge every first
use: a miss is a whole check, not a wrong result.

Proof: `prefer <file>` in a replay script. `Tests/Sema/Incremental/
replay_prefer.k`: `Inputs/live_prefer.replay` (the later of two files that
share instances is preferred: 6 refreshes, every step equal; with
`KAIRO_LIVE_PREFER_UNORDERED=1`, the old behaviour, 3 of the 6 are whole
checks) and `Inputs/plan_prefer.replay` under `KAIRO_LIVE_POISON`. On this
repository's graphs with the release compiler: kals graph, 5 steps
(`SourceManager.k` drained 20 files then `Server.k` and `LiveCheck.k`
preferred; `Tuning.k` with the entry preferred; `SourceManager.k` with
`FrontendAction.k` preferred at once; `Json.k` with `Completion.k`;
`ShellQuote.k` with `CompilerInstance.k`) and the compiler graph, 4 steps:
every step `refresh` and equal to a fresh run, no whole check. Whether the
preference was ever dropped for a step on these graphs was not counted
(`KAIRO_LIVE_DEBUG=1` prints it). On the kals graph `Server.k`'s set was 236
of the 239 queued files, so the order barely moved there: soundness is
shown, a gain in time is not. Not covered: a preferred file inside an import
cycle is its whole cycle, as everywhere.

### Aside: a text that is tried and not kept

**Built:** `LiveCheck::aside`, `LiveCheck::past_syntax`,
`kairo::aside_fork` / `aside_wait` / `aside_exit` (`Compiler/Native/Shims.hh`),
`CompilerInstance::admit_bodies_in_place` (`Driver/CompilerRecovery.k`),
`aside <edit>` in an `--incr-replay` script.

A language server has two texts per keystroke that must not become part of
the checked graph: the buffer while a line is half typed (it does not
parse), and the buffer with a completion marker in it. Every refusal of
`_tier_redo` comes AFTER the set was retracted and the file re-read, and a
refusal is a full check, so such a text may not enter the kept instance at
all. Rolling an in-place re-check back (the registry's drops and re-arms,
the foreign registry, the diagnostics, the detached contexts) would be a
second mechanism to prove.

**The copy.** The process is copied (fork: copy-on-write, so the cost is
the page tables and the pages one file's re-check touches), and the COPY
runs the ordinary first tier of the edit, reports, and ends through
`aside_exit` (no destructor of the original's state runs in it). The
original never saw the text: its graph, its queue, its overlays and its
replaced trees are untouched by construction, and what is proven about a
first tier is all that has to hold in the copy. The copy has the calling
thread only; a re-check in place runs on its caller's thread
(`FrontendAction::refresh`), and the header sets' workers are idle between
steps (`wait_all`). Windows has no fork: `aside_fork` is -1 there and the
caller falls back.

In the copy two switches are set:

- `aside`: a re-check that cannot be done in place is REFUSED (`mode:
  "refused"`, `why`), where the kept instance would take a full check;
- `past_syntax`: a re-parse that reports diagnostics is admitted as
  `--check-past-syntax-errors` admits a file (`_admit_bodies`): every file
  of the step's group that has syntax errors has them all inside function
  bodies the parser kept them in (`_bodies_hold_errors`), every new
  diagnostic is located in such a file, and their error count is exactly
  the sinks'. The bodies are dropped, the parser's diagnostics become the
  file's own, and Sema checks the rest. Anything else: `a syntax error
  outside a function body` (or `a diagnostic from before Sema`), refused,
  with the parser's diagnostics left in the per-file list without an owner.

A copy does not ask `tier_finish` (what one refresh decides at its end is
about the result once every importer is re-checked: an instance's first
use, a stand-in's layout): it reports the edited file and never gets there.
Found by the entry file, whose first tier leaves no queue: a name nothing
declares (a completion marker) was refused there for a re-armed instance.

`past_syntax` is for a throw-away instance only: in a kept one the files
that import the file would be re-checked against signatures whose bodies
were never checked, and the drained result is not one a run prints.

**The oracle, extended** (`incr_replay_check.py`, `aside <edit>`; needs
`--two-tier --overlay`). The live side forks at the `aside` line, the copy
applies the edit to its buffers and prints the file's diagnostics
(`== incr-replay aside <n> <file>`); the clean side applies the edit, runs a
fresh `kairo --type-check-only --check-past-syntax-errors`, and takes the
edit back. Compared: the primary diagnostic lines located in the file. And
every later step is compared as always, which is the proof that the aside
left nothing behind. `Tests/Sema/Incremental/replay_aside.k`
(`Inputs/aside`, `Inputs/aside.replay`): three broken texts of one body in a
row and the fix, with a semantic error in another function of the file that
each aside has to report; an error outside every body (`refused`); a file
broken while another file's importers are queued, before and after a
`drain`; a file broken, another file edited and kept, the first still
broken, then fixed; the entry (no importers, so no queue) with an undeclared
name and with a broken body.

### Not proven (phase 5)

- The "import it to use it" note for an extension in a QUEUED file that the
  re-checked file does not import (see the rule): no fixture has that error.
- An EDIT's first tier can still land ahead of the file that first used an
  instance it names (measured above: 1 in 3 out-of-order edits, a whole
  check). `prefer` no longer has that cost ("Preferred order").
- **Proven wrong, not fixed** (`Inputs/rearm.replay`): a conformance that
  fails in a file because the implementing extension is in a file it does not
  import is worded by whether that extension's target was resolved when the
  file was checked. A fresh run says "no member 'name_len' with the
  requirement's signature"; a re-check of `other.k` alone says "implemented
  by an extension this file does not import", with a note. Same error code
  and place, another message and one more note; the base compiler does the
  same. The cause was not traced: the likely one is that the fresh run
  checks `other.k` before `num.k`, so the extension is not resolved yet
  (`_hidden_unresolved` against `_hidden_by_type`, above).
- Everything "Not proven" under phase 4 except overlays, which are
  honoured and compared.

## The four changes to Sema

These are the re-architecture. Each is behaviour-preserving for a normal
build and lands separately.

1. **Ownership and retraction for every shared store.** Each store's write
   API takes the file on whose behalf it writes, and each file keeps a ledger
   of what it caused: instances minted, claimed and made live; partial and
   explicit specializations registered; conformance rows; ring links; thunks
   stamped. `retract(fid)` undoes the ledger. One-shot flags become
   per-requester (an instance is "checked for X"), so retracting X re-arms
   exactly what X did. Canonical types are not retracted: an entry keyed on a
   dead declaration is unreachable and is swept.
2. **Importers read interfaces, not trees.** What an importer needs from an
   importee after lowering today (thunks, purity, panic sets, enum and
   nullable layout) becomes interface facts computed at Checked. Lowering
   then produces a tree only codegen reads, a file can be checked without
   being lowered, and a check-only tool stops at Checked. This removes
   finding 4 and is what lets the editor path skip lowering altogether.
3. **Stable declarations across a re-parse.** When file F is re-parsed, each
   new declaration is matched to the old one by `DeclId`. A match keeps the
   old node's address and takes the new node's contents, so every pointer
   another file holds stays valid. An unmatched old declaration is
   tombstoned and its logged readers are re-checked. Exported declarations
   live in an arena that outlives a re-parse; bodies live in one that does
   not.
4. **Per-file diagnostics.** A file's diagnostics stay with its record
   (including an instance's, attributed to the use that caused them) instead
   of being drained into an engine list with no owner, so a re-check
   replaces exactly that file's.

## Re-checking a file

1. Re-parse F (the buffer or the disk). Match declarations (change 3).
2. `retract(F)` (change 1). Check F to Checked.
3. Compare each exported declaration's `I` with the stored one, and the set
   of names per scope.
4. For every logged read that step 3 invalidated, the reader is re-checked
   the same way. A body-only edit of a non-generic function invalidates
   nothing and stops here.
5. Files whose records are unchanged are not touched. Codegen then runs for
   the files whose stream changed, as today.

A batch build is the same loop with "re-parse" replaced by "the stored
record's `M(m)` no longer matches", and records loaded from disk instead of
kept in memory.

## Phases

A later phase does not start on a red earlier one.

| Phase | What it is | State | What it buys |
|---|---|---|---|
| 0 | Binary AST writer and reader, round-trip verified over the corpus ([Serialization.md](Serialization.md)) | built | the format everything else stores in |
| 1 | `DeclId`; dependency logging; `I(decl)` / `I(m)` at Checked; `--dump-interface` and `--dump-deps` print them. No reuse | built, except per-file diagnostics (change 4), which phases 3 and 4 provide as rendered text and as objects | the facts, and tests that pin "a body edit changes no `I`, a signature edit changes exactly its readers" |
| 2 | Module records with hashes only; a run whose inputs are all unchanged skips parse, Sema and the key fill. The hit is decided by the whole-input check rather than `M(m)` over the rows (see its section) | built, behind `--incremental-sema` (off unless given) | the no-change build: about 13 s to about the link (debug compiler, measured: 50.9 s to 4.8 s) |
| 3 | The re-check plan from the stored rows, proven by `--incr-verify` (`--print-incr-plan`). Interfaces serialized and loaded, so a changed file's imports are loaded and not re-checked | plan built, behind `--incremental-sema`; interfaces not built (blocked, see Phase 3), so nothing is reused | one-file edits in a batch build cost one file, once interfaces load |
| 4 | The live API (`LiveCheck`), per-file diagnostics as objects, `--incr-replay` and its oracle, re-check in place of a refresh set (a file and its importers). Changes 1, 2 and 3 as designed are not built | built; in place is opt-in (`LiveCheck::in_place`) | re-check in place |
| 5 | kals keeps one process per entry and calls replace-a-file, in two tiers: the edited file at once, the files that import it in the background; the worker-per-run path stays as the fallback and the crash boundary (see Phase 5) | built; on by default in kals (`liveCheck: false` or `KALS_LIVE_CHECK=0` turns it off) | an edit of any file that is not in an import cycle: 70 to 150 ms in the compiler, 130 to 210 ms from `didChange` to the installed result |

Phases 1 and 2 need none of the four changes except 4. Phase 3's plan
needs none either; its loading of interfaces needs change 2 and a
serialized Sema section.
Phase 4 is the large one.

## The rule for reuse

For reuse (phases 2 to 5), the rule from Incremental.md holds unchanged: for
a sequence of edits (body, signature, private field, generic body, header,
flag) every incremental result equals a clean one: objects byte for byte,
diagnostics, and the language server's snapshot.

## Requirements on phases 4 and 5

File-level re-check does not meet the editor target. The whole-graph run is
about 30 µs per line (9.4 s over about 300k lines), so re-checking one
3,000-line file is about 100 ms before any reader, and a hub file has
hundreds of readers. These are requirements, not implementation choices; the
built live check re-checks a refresh set (a file and the files that import
it, Phase 4), so it meets neither requirement 1 nor the early cutoff of
requirement 2:

1. **Declaration-level re-check.** The unit that is retracted and re-checked
   is a declaration, not a file. An edit inside one function body re-checks
   that body only; the target is 1 to 2 ms. `retract` (change 1), the
   dependency rows and the per-file diagnostics (change 4) are therefore keyed
   by `DeclId`, with the file as the fallback when an edit cannot be confined
   (a top-level declaration added or removed, an import changed, a parse that
   does not recover inside the declaration).
2. **Early cutoff.** After a declaration is re-checked its `I(decl)` is
   compared with the stored one. Unchanged: nothing downstream is touched.
   Changed: readers are found through the `(DeclId, which)` and
   `(F, scope, name)` rows, never "every importer of the file".
3. **Cancellation checkpoints.** Sema polls a revision flag at statement
   granularity (and per instantiation), so a check of a stale revision stops
   in well under a millisecond instead of running out.
4. **Snapshots.** One writer re-checks; readers (hover, tokens, signature
   help) see an immutable snapshot tagged with its revision and are never
   blocked by the writer. Publishing a snapshot is a pointer swap.

### Measured: where a run goes

Release compiler, `--type-check-only --time-passes`, the compiler's own
graph (377 files), one run: 8.84 s.

| Region | Wall | Share |
|---|---|---|
| Sema, expression typer | 3.68 s | 42% |
| Sema, chain binding | 1.83 s | 21% |
| Sema, imports | 1.39 s | 16% |
| Sema, every other check and pass together | about 1.4 s | 16% |
| C++ headers: header-set build and index | 2.42 s | 27% (overlaps the start of Sema) |
| Parse, all files, on the pool | 0.98 s of work | |
| Clang startup | 2.7 ms | |

Reading: the imported C++ is about a quarter of a run, under the "third"
that would put it first. It is a once-per-process cost, so a process that
stays up (phase 5) pays it once, and the on-disk preamble below is a
cold-start improvement, second in order. Kairo Sema proper is about 6 s and
two passes are two thirds of it; Sema's wall time equals its self time, so
it runs the files one after another. Incremental re-check is the first-order
work, as planned. One run, so the shares are indicative.

Persistent preamble (not built), for when cold start is the complaint. If
loading the imported C++ (188 headers on the compiler's own graph) were a
third or more of a run, the first-order work would be a **persistent
preamble**, ahead of incremental Sema:

- the imported C++ AST stays alive in the process and is deserialized lazily
  (PCH / ASTReader style), not eagerly;
- it is stored on disk keyed by header contents and flags, so a restart does
  not pay the cold cost;
- it is invalidated only when the set of C++ imports or a header changes;
- one preamble per workspace is shared by every entry's state, not copied.

Adding a C++ import to a file is the worst edit there is. It is outside the
latency budget and reports progress instead (LanguageServer.md section 11).

### How it is measured

- **Edit traces, not single edits.** Recorded typing sessions replayed
  against the compiler's tree, each edit tagged: body, signature, new
  top-level declaration, hub file, file importing C++, import-set change.
  p95 is reported per kind.
- **Instruction counts** (`perf stat`), not wall time, are what a gate
  compares: this machine's load makes wall time unusable.
- **Resident memory** of the long-lived process is tracked per run.
