# Incremental compilation

How the compiler reuses work across runs: what is cached under `--cache-dir`, what each artifact is keyed by, and what invalidates it. **Phase 1 is implemented** (`Compiler/Driver/ObjectCache.k`); [Status](#status) lists what was built and every deviation from the text below. This document is the contract the implementation is built to; where it and the code disagree, the disagreement is a defect (the deviations listed there are the known ones).

## The two rules

1. **The unit of recompilation is one file.** A Kairo file is one translation unit and produces one object. A run recompiles the files whose object key changed and reuses every other object from the cache. There is no finer unit: a file is either recompiled whole or reused whole.
2. **A dependent is invalidated by a change to what it can see, not by a change to the file.** Editing the body of `fn foo()` recompiles only the file that defines `foo`. Changing `foo`'s parameters, return type or anything else in its signature recompiles every file that imports it. What a dependent can see is the file's **interface**: its signatures plus the ABI layout of everything it exports ([The interface](#the-interface)). Either changing invalidates the dependents' cache.

Everything below makes those two rules exact.

## Terms

| Term | Meaning |
|---|---|
| module | One Kairo file and its declarations. `Lib/builtin` and `Lib/std` files are modules like any other. |
| dependent | A module that imports another, directly or through a re-export. |
| interface | Everything a module exposes that a dependent's compiled code can depend on ([The interface](#the-interface)). |
| interface hash `I(m)` | A hash of module `m`'s interface. |
| object key `O(m)` | The key `m`'s object is stored under ([Object key](#object-key)). |
| toolchain fingerprint `F` | The part of every key that comes from the compiler and the options, not the source ([Global invalidation](#global-invalidation)). |
| cache directory | The directory named by `--cache-dir`. Nothing is cached without it. |

## The interface

The interface is defined by what a dependent's object can depend on, not by what the source spells. It is computed after Sema and the lowerings, from the same tree codegen renders, so every fact the compiler infers from a body and lets callers rely on is part of it.

A module's interface contains:

| Part | Why a dependent depends on it |
|---|---|
| Every visible declaration's signature: name and module path, generic parameters and bounds, parameter types and modes (`const`, `@inout`, `@move`), return type, panic set, calling convention (`@preserve_*`), `const fn` / `@pure`, `-> !`, `unsafe`, visibility | The call a dependent emits is spelled from it |
| **Inferred** facts that change a caller's code: `ParamPassInference`'s inferred `const T&` (a body that starts mutating a parameter changes the parameter from `const T&` to by-value, which is an ABI change), inferred purity (`-finfer-purity`), an inferred panic set (it changes the return type to `Panic<T, E...>`) | The emitted declaration differs, though the source signature did not |
| The layout of every record a dependent can name or hold: field types and order, **private fields included**, size, alignment, bases and their offsets, the vtable (the set and order of virtual methods) | A dependent allocates, copies and offsets into it |
| Enum and ADT layout: variants, payload types, discriminant values, tag width, niches | A dependent's `match` and construction read it |
| Class lifecycle facts: trivially copyable, trivial destructor, move-only, the derived `op =` / comparisons | They decide how a dependent passes and destroys a value |
| Bodies that are compiled into the dependent: generic functions and methods (one C++ template, instantiated where used), `inline` functions, `eval fn` bodies a dependent evaluates, macro bodies, default argument expressions (evaluated at the call site) | The body is compiled as part of the dependent |
| `eval` constants' values, and type aliases | They are folded into the dependent |
| The re-exported interface of `pub import`s | A dependent sees it as this module's |

Not part of the interface: the body of a non-generic, non-inline, non-`eval` function; private free functions and private types that no interface part reaches; comments, formatting, and source locations (see [Debug info](#debug-info)). A body edit to such a function changes only the owning module's object key.

`I(m)` is the hash of the canonical rendering of these parts: the interface entries `m` contributes to the [interface PCH](Codegen.md#the-interface-pch), each keyed as `IncludedDecls` keys it, with its tokens' kinds and spellings, plus the layout facts above. Hashing the rendered C++ entries, not the Kairo source, is what makes inferred facts and layouts count without listing them by hand: if a dependent would be compiled against different C++, the hash differs.

Layouts are transitive by construction: a record that holds another module's record by value has that record's size and alignment in its own layout, so a layout change in `B` changes `I(A)` when `A` embeds `B`'s type, and `A`'s dependents recompile too. A dependent that only names `B` through a pointer is not affected by `B`'s layout.

## Object key

`O(m)` is the hash of everything clang is given to compile `m`:

- the toolchain fingerprint `F`;
- `m`'s own stream: its bodies, its tier-3 explicit instantiations and `extern template`s, its eval bindings ([Codegen.md#tiers](Codegen.md#tiers));
- for every interface entry and body `m`'s plan names from other modules, that entry's hash (not the whole `I(dep)`: a dependent that uses only `foo` is not recompiled when `bar` in the same module changes signature);
- the content hashes of the C and C++ headers in `m`'s ffi closure ([FFI headers](#ffi-headers));
- the instance-home assignments that decide which instances `m` defines and which it declares `extern` ([Instantiation homes](#instantiation-homes)).

Rule 2 follows: a body-only edit to `foo` changes `m`'s own stream, so `O(m)` changes and nothing else does. A signature edit changes `foo`'s entry hash, so `O` changes for `m` and for exactly the dependents whose plans name `foo`.

## Instantiation homes

Every generic instance has exactly one home TU that holds its explicit instantiation definition; every other TU declares it `extern template` ([Generics.md](Generics.md)). Today the home is the first TU in import order that names the instance. That makes homes a global fact: adding a use of `Vec<Foo>` in an early module can move `Vec<Foo>`'s home and change two other objects whose sources did not change. The implementation must do one of:

- **(recommended)** Move every homed instantiation into one build-level instances object, keyed by the sorted set of instances and their entry hashes. Source TUs then only ever declare instances `extern`, and their objects stop depending on which other files exist.
- Or include the home assignments a TU defines and declares in `O(m)` (the last item in [Object key](#object-key)), accepting that a new use can recompile the TU that loses a home.

## FFI headers

A C or C++ header is part of every TU whose ffi closure includes it. The key uses a content hash of each header in the closure (clang's dependency list for the header set, hashed by content, not mtime), plus the header-set configuration. Editing a system or project header recompiles the TUs that import it, and their dependents only if the header changes their interface.

## Global invalidation

The toolchain fingerprint `F` is part of every key. A change to any of its parts invalidates every object compiled under the old value:

| Part | Rule |
|---|---|
| Kairo version | `MAJOR.MINOR.PATCH` counts: `0.2.0` to `0.2.1` invalidates. Pre-release and build metadata after the version core (`+dev.20261107`) does not. |
| Cache schema | `CACHE_SCHEMA`, an integer in the compiler, bumped by any change to the cache layout or to how keys are computed, and by any change that alters emitted objects without a version bump (see [Development builds](#development-builds)). |
| LLVM and clang | Their versions and the fork's revision (they ship together in the bundled toolchain). |
| Target | Triple, CPU, target features, ABI options. |
| Compile options that change objects | Optimization level, debug-info kind, `-D` / `--cxx-define`, language and feature `-f` flags, sanitizers, `-ffp-contract`, `-finfer-purity`, code model, PIC/PIE, the builtin and std roots, the sysroot. Normalized (sorted, defaults made explicit) so the same options in another order hash the same. |
| Diagnostic-only options | `-W`, `-A`, `--error-format`, colour: **not** part of `F`. They do not change objects; see [Diagnostics](#diagnostics). |
| Link options | Not part of `F` either. They only decide whether the link reruns ([Linking](#linking)). |

How an option interacts decides its place: an option that can change an object is in `F`, one that can change only the link is in the link key, one that can change only what is printed is in neither.

### Development builds

Two compilers with one version core can emit different objects (two development builds of `0.2.0`). The version rule above does not tell them apart, by design. `CACHE_SCHEMA` covers deliberate output changes. Anyone running a development compiler against an old cache directory should expect stale objects if a codegen change landed without a schema bump; `build.py` gives each pipeline stage its own cache directory and clears it per pipeline run, so the bootstrap never reuses a staging compiler's objects for the release build.

## Debug info

Without `-g`, source locations are not part of any key: moving a function down ten lines recompiles nothing outside its own file, and its own file only because its stream changed. With `-g`, line tables are in the objects, so locations are part of the TU's own stream key; they are still not part of `I(m)`, so a dependent is not recompiled because an imported declaration moved.

## Diagnostics

A reused object must not lose its file's warnings. Each cached object stores the diagnostics its compile produced (Kairo's and clang's, after `-A` filtering, before rendering) in its [cache record](#keys-in-the-object). A run that reuses the object replays them through the current renderer and filters, so `--error-format` and `-W` changes take effect without recompiling. An object whose compile reported an error is never stored.

## Linking

The link reruns when any object it takes changed, when the object list changed, or when the link key changed: link options (`-l`, `-L`, `--rpath`, `--static`, `--strip*`, linker flavour, LTO mode), the runtime and library objects' keys ([Driver.md](Driver.md#runtime-and-the-kairo-library)), and the output path. The object list is always the run's own, never a glob of the cache directory ([Linking.md](Linking.md)).

## What still runs every time

Phase 1 (first implementation): parsing, import resolution and Sema run for the whole program on every run (a whole-compiler type-check is about 7 s); only codegen and clang, about 80% of a build, are skipped for unchanged object keys. This needs no serialized Sema state and is correct by construction, because the keys are computed from the same tree a full build renders.

Phase 2: serialize each module's checked interface (its Sema facts and interface entries) keyed by `I(m)` and its own source hash, so an unchanged module's Sema is loaded rather than rerun. Only modules whose source changed, or one of whose imports' `I` changed, are re-checked.

## Keys in the object

Every object carries its own cache record, so an object is self-validating: copied to another machine, shared between checkouts, or handed over by hand, it is reused wherever its keys match and rejected wherever they do not, with no side file needed.

The record is a section in the object:

| Format | Section | Kept out of the linked output by |
|---|---|---|
| ELF | `.kairo.cache` | `SHF_EXCLUDE` (the linker drops it) |
| Mach-O | `__KAIRO,__cache` | `S_ATTR_DEBUG`-style no-load attribute; the linker does not copy it |
| COFF | `.kcache` | `IMAGE_SCN_LNK_REMOVE` |

It holds, versioned by `CACHE_SCHEMA`:

- the toolchain fingerprint `F` and its parts (so a mismatch can say which part differed under `-v`);
- `O(m)`, `I(m)`, and the hash of each interface entry and body the module's plan used from other modules (the dependency edges the key was built from);
- the module path and the content hash of the source the object was built from;
- the FFI header content hashes and the instance-home assignments that went into `O(m)`;
- the diagnostics the compile produced ([Diagnostics](#diagnostics)), so a reused object replays its warnings wherever it is reused.

A lookup recomputes the wanted `O(m)` and accepts a candidate object only if its embedded `O(m)` equals it; the file name is a hint, never the proof. A stripped or foreign object (no record, or a record of another schema) is a miss.

For a shared object to be valid elsewhere, nothing in a key may depend on the machine: module paths are relative to their module root, absolute paths in debug info are already remapped by `--debug-prefix-map` / `--reproducible` and must be in that remapped form when hashed, and host-only state (mtimes, the cache directory's own path, the user name) is never hashed. `F` includes only what changes the object.

## The cache directory

Layout under `--cache-dir=<dir>`:

```text
<dir>/kairo-cache-v<CACHE_SCHEMA>/
  <F>/                       one toolchain fingerprint
    objects/<O(m)>.o         content-addressed objects, each carrying its own record
    iface/<I(m)>.pch         interface PCH artifacts (Codegen.md)
    instances/<key>.o        the build-level instances object
    index/<module path>      per module: the last O(m) it was built with (a lookup shortcut)
  lock                       build lock
```

The `index` is only a shortcut: it can be deleted, or rebuilt by reading the records of the objects present. Every fact a decision needs is in the object itself, so dropping a shared object into `objects/` (or pointing `--cache-dir` at a directory of objects from another machine with the same `F`) is enough for it to be reused.

- Writes are atomic: write to a temporary name in the same directory, then rename. A crash leaves no partial artifact under a real key.
- Two builds may share a directory: lookups are lock-free, the manifest update takes `lock`. Content addressing means two builds that compute one key produce one artifact.
- A different `F` never sees another's objects; switching between debug and release, or between targets, keeps both sets.
- The directory is bounded by a size policy (least recently used fingerprints and objects are removed first); the existing ThinLTO cache policy ([Performance.md](Performance.md)) is the model.
- Without `--cache-dir` nothing is cached and every run is a full build, as today.

## Correctness rules

- A key must cover every input the artifact depends on; when in doubt, an input goes in the key. A false miss costs time; a false hit is a miscompile.
- A reused build must be byte-identical to a full build with the same options, apart from the cache record sections, which the linker drops.
- An object reused from another machine or checkout must give the same result as one built locally: its record, not where it came from, decides. The gate for the implementation: for a sequence of edits (body-only, signature, private field, generic body, header, flag), every incremental build's objects and binary equal a clean build's.
- Keys are computed from the tree codegen renders, after every lowering and inference, never from source text alone.

## Status

**Phase 1 implemented (2026-11-08).** Parsing, import resolution and Sema run for every file every run; a TU whose object key matches a stored object skips codegen and clang. Code: `Compiler/Driver/ObjectCache.k` (keys, record, store), `Compiler/Codegen/Sink/HashSink.k` (the stream hash), `CodegenJob::hash_stream` and the record emission in `Compiler/Codegen/Backend/CodegenBackend.k`, the reuse decision in `FrontendAction::_codegen`, `Compiler/Native/KObjCache.hh` (xxh3-128, reading the record section). Tests: `Tests/CLI/Driver/incremental_*.k`.

### As built

- **The key.** `O(m) = H(F, stream(m), headers(m), clang -W words, interface-PCH shape)`, xxh3-128. Every part is `m`'s own, none the graph's ([Shared across graphs](#shared-across-graphs)). `stream(m)` is the hash of the exact token stream `CodegenBackend::fill` hands clang for `m` (no interface-PCH pruning, no record): each token's spelling, plus, with `-g`, its file and line:column. That stream is `m`'s own stream plus every interface entry and body its plan names from other modules (only those), its tier-3 instantiations and `extern template`s, and every inferred fact the emitters spell, so [Object key](#object-key)'s first four items are covered by construction rather than listed. It is rendered into a `HashSink` on the pool, after `prepare_shared`, by the same plan/emitters the real fill runs.
- **Instantiation homes**: the second option of [Instantiation homes](#instantiation-homes). The homes a TU defines and the instances it declares `extern` are in its stream, so they are in its key; a new use that moves a home recompiles the TU that loses it. The home is chosen at codegen, from the TUs that hold the instance, not from the Sema order ([Shared across graphs](#shared-across-graphs)).
- **Where the reuse decision is made**: `FrontendAction::_codegen`, after every job's output path and `prepare_shared` and before the interface PCH. Hits get `written = outs` and never reach the fan-out; misses compile with the record appended to their stream. The interface-PCH decision (which flavours build one) is taken over **every** TU, reused ones included, exactly as a clean build takes it, and the PCH of a flavour is built over all its TUs when at least one of them compiles; so a compiled TU sees the PCH a clean build would give it. Whether a TU compiles under a PCH is in its key; with `-g`, so is the module of the PCH's first TU (its TUs go in module-path order), which writes the stream helpers every TU of the PCH shares (`__kairo_fn`, `__kairo_raw_fn`, anchored at that TU's first byte), so a `-g` object compiled under the PCH names that file in its debug info.
- **The record** is a top-level `asm` statement appended to the stream (after everything the key hashed): `.pushsection .kairo.cache,"e",%progbits` on ELF (SHF_EXCLUDE), `.section __KAIRO,__cache,regular,debug` on Mach-O (S_ATTR_DEBUG), `.section .kcache,"dn"` on COFF (IMAGE_SCN_LNK_REMOVE), checked on all three. Text lines: magic, schema, F, O, module path (`::`-joined, or the file name for a pathless TU), source content hash, stream hash, headers and diag hashes, F's parts (`f.schema`, `f.version`, `f.build`, `f.clang`, `f.triple`, `f.options`), `end`. A record that does not start with the magic, is not this schema, or does not end with `end` is a miss.
- **The store**: `<cache-dir>/kairo-cache-v<CACHE_SCHEMA>/<F>/objects/<O>.o` (`CACHE_SCHEMA` 2 since the keys became per TU, 2026-11-08). The TU's object is still written where it always was (`<cache-dir>/<module path>.o`, the link input); a hit copies the entry there, or does nothing when that file's own record already names the key **and** the store holds the entry (the store decides: an object clang reported on carries a record but is never stored, see Diagnostics). Writes go through a private name and a rename. A damaged entry (cut short, a record naming another key) is replaced by the next compile of its key. `--force-recompile` skips the lookup.
- **`-v`** logs each TU's verdict: `incremental: reused <module> (<O>)`, `incremental: compiling <module> (changed: stream|headers|diag|f.<part>)`, from the record of the object at the TU's output path. `--print-stats` prints `[stats] incremental: N reused, M compiled, K stored`.
- **gc**: after a run that stored anything, entries older than 30 days (by mtime) and private copies older than a day are removed, as the runtime cache does.

### Deviations from this document

1. **Clang's `-W` words are in every key** (as `diag`, beside F, not in it). The record does **not** store diagnostics ([Diagnostics](#diagnostics)): an object whose compile drew any clang diagnostic is compiled but never stored, so it compiles, and reports, every run; an object stored under one clang warning set could lack a warning another set enables, so the set keys it. Kairo-only `-W`/`-A`, `--error-format` and colour do not reach clang and do not invalidate. Kairo's own codegen-time diagnostics (EmitIR's I011W, SC241W) need no storage: the key's fill reports them on every run, and they are kept for a reused TU (its replay) and dropped for a compiled one (whose own fill reports them again). Storing clang's diagnostics in the record is the remaining work for criterion "diagnostic-only options keep the objects".
2. **Development builds key the compiler build.** `f.version` is the `MAJOR.MINOR.PATCH` core, as specified; but a version carrying `+dev`, `+rc` (every build today) or `unknown` adds `f.build`, the content hash of the compiler executable. Without it, the lit suite and `build.py --debug` (which re-run against caches an earlier compiler filled) would serve stale objects after any codegen change. A release version keys by its core alone.
3. **Headers are per TU, but compiled against the whole graph's.** Every TU loads the whole graph's header sets (one merged PCH); its key holds only the header files it can reach (`ObjectCache::tu_headers`): from the TU and from every module a token of its stream came from (an imported signature, an inline body, a witness row of a module it does not import; `HashSink::files`), every module they import, transitively, and the files of every ffi closure on the way (`TranslationUnit::import_edges`), plus any header a token came from directly. Each file by name (with `-g`, by path) and content, sorted by path, with `c` for a direct `ffi "c"` import; plus the merged-PCH verdict and any `-include` file. A header edit recompiles the TUs that reach it, not every TU. Two things a TU does not reach can still move its object, and each is handled or assumed: (a) with `-g`, debug info names the **first** declaration of a header entity, and C library headers repeat typedefs behind guards (glibc's `ssize_t` in `<stdio.h>`, `<unistd.h>` and `<sys/types.h>`), so whichever another module's import put first declares it: the key also holds every **system** file of the merged PCH up to the last system file this TU reaches, in the PCH's order, with its content (a file after it cannot declare first what this TU uses, since the entity is declared in a reached file too); (b) a non-system header (project, LLVM) is assumed to define each entity once behind one guard, so the order of unreached ones never moves a declaration, and an unreached header is assumed not to change the meaning of reached code (a macro, an overload found by ADL). Every reused object of the kairo/kcc/kfmt/kld proof below was byte-identical to a clean compile, in debug and in release.
4. **Path-valued cc1 words are dropped from `F`.** The header search roots (`-I`, `-iquote`, `-isystem`, `-idirafter`) always: they reach an object only through the headers they find, hashed per TU by content (and with `-g` by path), so kfmt's extra `-I Extras/Formatter` does not split its store from kairo's. Without `-g` also the resource dir, sysroot and compilation dir. With `-g` those stay, and the stream hash names each file by its absolute path, so **`-g` keys are not relocatable** (`--debug-prefix-map` / `--reproducible` remapping is not applied before hashing). The same compiler in the same checkout reuses `-g` objects normally.
5. **`-g` and imported positions.** With debug info, a dependent's line tables hold the lines of the imported declarations it uses, so the stream hash includes each anchored token's line:column. An edit that moves an imported declaration recompiles the dependents that name it; one that moves no line (most body edits) recompiles only its own file. The [Debug info](#debug-info) section's "a dependent is not recompiled because an imported declaration moved" does not hold for `-g`: it would break byte-identity.
6. **No `index/`, no `lock`, no `iface/`, no `instances/`.** Lookups go by the computed `O(m)` straight to `objects/`; there is no manifest to lock. The interface PCH is rebuilt per run (when anything compiles). No build-level instances object (homes are option 2 above).
7. **No per-entry hashes.** The record carries the stream hash, not one hash per interface entry used, so `-v` says `changed: stream` rather than naming the entry. The precision is the same: the stream holds only the entries the plan names.
8. **The link always reruns** ([Linking](#linking)'s link key is not implemented). It is cheap next to codegen but not free (about 2.7 s of the compiler's own release build).
9. **Size policy** is the 30-day age rule above, not an LRU bound.
10. **Only objects are cached**, one kind per run: `--emit` asking for `.s`/`.ll`/`.bc`, `--print-cg` and `--print-ir` compile as before.
11. **Known false misses** (correct, but wider than "exactly the dependents"): whether a TU compiles under an interface PCH is decided per flavour over the whole graph and is in every key (it does change objects: measured, on vs off differ in 28 of kld's 29 debug objects and 1 release one), so a file that pushes a flavour past `IFACE_PCH_MIN_BYTES` (or gives it its second TU) recompiles that whole flavour; with `-g`, a header added to the merged PCH before a TU's last reached system file recompiles it ((a) of deviation 3); and a fact Sema infers differently in another graph is in the stream, so the TU recompiles there (as in `kfmt`, below).
12. **Headers the stream asks for** (`system_header`: `<new>`, `<coroutine>`) are resolved by clang at compile time from the sysroot and are in no header set, so their content is not hashed; the clang version and (with `-g`) the sysroot path stand in for them.
13. **Per action, not per run**: `setup` hashes the compiler executable and `begin_run`/`tu_headers` the header-set files once per FrontendAction, so a run with several inputs pays that once per input.
14. **Instance homes are codegen's, not Sema's** ([Shared across graphs](#shared-across-graphs)): `InstanceEntry::home_fid` (Sema's first namer, D3) still orders M1's worklist, but the TU that writes an instance's explicit instantiation is chosen from the plans that admit it. `Tests/Codegen/mono_reached/swapped.k` was updated from the old rule (the home follows the entry's import order) to this one.

### Shared across graphs

One cache serves every tool built from one tree (`build.py` passes `<cache>/tu` to all, [BuildSystem.md](BuildSystem.md#cache-layout)), so a TU's key must not depend on the graph it was compiled in, only on the TU: after `kairo` is built, `kcc`, whose graph is `kairo`'s plus `Driver::Kcc`, compiles one TU. Four things were facts of the graph and are now facts of the TU (2026-11-08):

| Was | Now |
|---|---|
| `F` held `-D VERSION="kcc+dev.<date>"`, a per-tool, per-day cc1 word | the version is defined in the tool's meta object (`kairo_version_cstr()`, `-D KAIRO_VERSION_EXTERN`); `F` also drops the header search roots ([deviation 4](#deviations-from-this-document)) |
| `headers`: every file of every header set of the graph | `headers(m)`: the files `m` can reach ([deviation 3](#deviations-from-this-document)) |
| Plan entries ordered by fid (minted in the PP walk from the entry, so `Kairo.k` and `Kcc.k` number one module differently: 254 of 338 streams differed by order alone) | by the TU's own walk: a depth-first walk of its imports from the TU, then from the prelude (the walk the dependency scan makes from the entry, so the entry TU's order is unchanged), then every other file by module path (`EmitPlan::set_graph`, `_rank_of`) |
| An instance's home was its first namer in the one-thread order (decided by the entry) | among the TUs whose plan admits it, in the root of its Sema home: the least module path among those that import no other (transitively; one import cycle counts as one), which is the first namer with the entry's sibling order replaced by the module path; C++-identical instances (`*T` and `unsafe *T`, `usize` and `u64`) are homed as one (`EmitPlan::assign_homes`, a plan pre-pass, `GraphFacts`, ~0.7 s on the compiler's tree) |

Proof: `kairo` then `kcc`, `kfmt`, `kld` on one cache; then each of `kcc`, `kfmt`, `kld` clean into an empty cache, same `--out`; the binaries and every link-input object compared byte for byte. All identical, release and debug (`--reproducible`), 351 / 356 / 41 objects.

| Mode | `kairo`, empty cache | `kcc` after `kairo` | `kfmt` after both | `kld` after all |
|---|---|---|---|---|
| release (`--single --release`, `x86_64-linux-musl`) | 339 compiled, 40.7 s | **338 reused**, 1 compiled, 19.4 s (clean: 38.2 s) | 188 reused, 156 compiled, 31.6 s (clean: 38.6 s) | 28 reused, 1 compiled, 4.0 s (clean: 7.8 s) |
| debug (`-O0 -g`) | 339 compiled, 31.1 s | 19 reused, 320 compiled, 26.3 s (clean: 30.1 s) | 188 reused, 156 compiled, 23.3 s (clean: 30.4 s) | 12 reused, 17 compiled, 3.0 s (clean: 6.5 s) |

What still splits: in debug, the merged PCH's system-header order (deviation 3 (a); `kcc`'s extra headers move it for almost every TU); `kfmt`'s 156 are one inferred `__attribute__((const))` on `InstantiationRegistry::_row_hash`, which `-finfer-purity` decides differently in `kfmt`'s graph, in a header entry 149 TUs include. With the per-TU-only key (before the `-g` prefix), debug `kcc` reused 338 and was byte-identical, but `kld`'s `std/env.o` was not (`ssize_t` from `<stdio.h>` vs `<sys/types.h>`), which is why the prefix is in the key.

### Measured (compiler's own tree, 338 TUs, 24 threads)

| Build | First (empty cache) | No change | One Sema body edited |
|---|---|---|---|
| release (`x86_64-linux-musl`, `-O3`), per target | 34 s | 15 s (338 reused) | |
| debug (`-O0 -g`), `kairo` | 25 s (31.9 s wall) | 13 s (14.1 s wall, 338 reused) | 16 s (18.9 s wall, 1 compiled) |

The no-change build's remaining time is Sema (~7 s), the key's fill (`CacheKeys`, ~2.7 s; 3.4 s for a debug `kcc` since the keys are per TU) and the link (~2.7 s), plus `GraphFacts` (~0.7 s) since 2026-11-08. Every incremental binary was byte-identical to a clean build of the same tree (release with `--reproducible`; debug with `--reproducible`, since a non-reproducible debug build stamps its own build time into `.build_meta`).

Phase 2 (serialized Sema, the `iface/` artifacts, the link key) is not started; it is the function-API-level incremental compilation still to come. The interface-PCH design in [Codegen.md](Codegen.md#the-interface-pch) already partitions each TU's input into interface entries and own bodies, which is the split the keys above use.
