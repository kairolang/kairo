# Performance

Compile time and memory: how they are measured, how codegen runs in parallel, and the optimizations and container rules that keep the compiler fast. The codegen pipeline these sections refer to is in [Codegen.md](Codegen.md#pipeline); the Sema pass order in [Pipeline.md](Pipeline.md#sema-pass-order); threading of the build tool in [BuildSystem.md](BuildSystem.md).

## Benchmarks

### Workloads

| Workload | What it measures |
|---|---|
| Self-build | the release compiler building the compiler's debug configuration, cold (fresh `--out`, so no object cache), registry object reused: `python3 build.py --debug --out <fresh> --registry-object <registry.o> --no-prebuild --no-postbuild kairo`. 316 TUs. |
| Self-build, type-check only | the same graph under `--type-check-only` |
| Small program | one `test.k` with 23 emitted TUs and 4 header sets; the codegen spike's input |

Machine: AMD Ryzen 9 7900X, 12 cores / 24 threads, Linux.

### Measurement rules

- Wall times are taken without `--print-stats` / `--time-passes`. Both arm clang's time-trace profiler per TU and serialize its JSON. At granularity 0 that inflated a large build's backend by about 50%: LLVM's profiler holds one process-wide lock for each TU's whole write, so the workers' harvests queued behind each other. At the 50 µs granularity used since, the debug kairo self-build is 22 s traced against 21 s plain. Per-phase breakdowns come from `--print-stats` and are compared only with each other.
- `KAIRO_CLANG_TRACE_DIR` (`Compiler/Native/KTimeClang.hh`) dumps each TU's clang trace when profiling is on. `--print-stats` also prints the memory probes, as `[stats]` lines after the timing table: arena bytes by kind, the largest TU and the live header-set AST bytes after Sema and after codegen (`FrontendAction::_dump_mem_stats`), the arena growth per Sema stage and lowering pass (`Compiler/Sema/Sema.k`), and with `-finfer-purity` the const / pure counts it inferred.
- An optimization that must not change output is gated on byte-identical objects: every object of a cold self-build compared with the previous run's. Only `kairo_meta.o` (build metadata) may differ.
- `perf_event_open` is restricted on the reference machine: only `-e cpu-clock:u` on a child process. Detailed profiles come from callgrind.

### Self-build history

Each row adds one change to the row above. Hashes identify the commit; the changes are described in [Compile-time optimizations](#compile-time-optimizations).

| Change | Wall | Peak RSS |
|---|---|---|
| baseline (1e166f8d) | 259 s (with stats) | 44.2 GB |
| toposort, header index, tag hiding | 126 s | 42.0 GB |
| codegen workers = pool size, claim hint | 113 s | 46.6 GB |
| `PCHInstantiateTemplates` | 79 s | 42.0 GB |
| `_needs_complete` memo, set index, closure memo | 66 s | 42.0 GB |
| extension index skips headers, integer closure walk | 63.5 s | 42.1 GB |
| merged PCH even for one set | 62 s | 35.4 GB |
| header index skips frozen headers | 56.4 s | 35.1 GB |
| header sets freed when done (b562d86e) | 55 s | 27.9 GB |
| `ASTWriter` copy-on-change (7966a600) | 54 s | 21.7 GB |
| runtime compiled during Sema (be50e6d3) | 52.5 s | 21.8 GB |
| lld ThinLTO cache (573d2782) | 48.0 s | 21.8 GB |
| parallel TU emptiness checks (2ee00363) | about 45 s | 21.9 GB |
| lazy `ArenaList` arena (342e7ec0) | about 43 s | 21.8 GB |
| header function bodies skipped (4deec0da) | 39 s | 16.2 GB |
| ADL scopes through a set (fae70b66) | about 39 s | 16.1 GB |
| one shared header parse (d0b2d760) | 32 s | 10 GB |
| interface PCH (release self-compile, not the debug self-build) | 31.3 s to 29.4 s | 7.24 to 6.13 GB |

Baseline user CPU was 1529 s with about 5.9 of 24 threads busy; at 39 s it was about 478 s. The 48 s and later rows assume warm runtime and ThinLTO caches; the first build after a compiler rebuild fills them and costs about 4.5 s more. The whole-graph `--type-check-only` went from 29.5 s / 27.9 GB to 22 s / 15.2 GB before the shared header parse and 14.6 s / 2.9 GB after it.

The baseline's shape, by cores busy: parse on about 21 cores (0 to 10 s); header indexing and Sema on one core (10 to 60 s); the codegen pre-pass (`EmitPlan` per TU) on one core (60 to 115 s); the backend on 9 to 12 cores (115 to 250 s, 717 s CPU of clang parsing each TU's tokens).

Two later changes were measured separately: the `TokenSink` claim walk took the release `Registry.k` object from 34 min to 8.4 s, and the lock-free imm-table mirror took a self-build from 34.2 s to 28.7 s on glibc and from 42.7 s to 28.8 s on static musl, where system time fell from 344 s to 11 s.

### Small program

`kairo test.k` (release) takes 0.42 s wall with one merged codegen PCH; with a PCH of only the TU's own set and the other sets parsed textually it took 0.93 s. The compiler's peak RSS on it is 378 MB. Per TU with the merged PCH, the empty-body overhead (headers, PCH, action) is 1.6 ms, parse and Sema of the emitted C++ about 1 ms, and -O0 IRGen plus machine code about 1.3 ms; `test.k` itself is the one heavy TU (22 ms at -O0, 75 ms at -O2). The full matrix and its raw results were recorded with the spike and are not in the repository.

## Parallel codegen

`FrontendAction::_codegen` (`Compiler/Driver/FrontendAction.k`) compiles each TU on a clang `CompilerInstance` of its own, side by side on the compiler's `ThreadPool`. It runs in three steps.

1. **Pre-pass, driver thread.** One `CodegenJob` per TU (`Compiler/Codegen/Backend/CodegenBackend.k`): output paths, header sets, print flags. Two TUs that map to one object name (a pathless `builtin.k` and the builtin root) give the later one a `-<fid>` suffix. `EmitPlan::prepare_shared` fills the one plan cache that other TUs' plans read (`TranslationUnit::cxx_escaping`, through `CXXSpell::is_anon`). `CodegenRun::mount` lists every byte the TUs' file systems will hold (the merged PCH, or each set's PCH and wrapper) and sets the `mounted` flags. Whether each candidate TU is empty is decided on the pool (`_tu_is_empty`), the verdicts read back in order.
2. **Fan-out.** `CodegenQueue` sorts jobs by size, biggest first, and workers take the next job from an atomic counter. `CodegenJob::run` is the whole TU and shares nothing mutable: its own `CompilerInvocation` copy and `CompilerInstance` (FileManager, SourceManager, TargetInfo, DiagnosticsEngine), its own `ClangLocMap` (FileIDs belong to one SourceManager), a `ClangDiagAdapter` writing into its own `BufferedDiagSink`, and its own VFS overlay (`ClangBackend::codegen_vfs`: the real file system under the fan-out's one in-memory layer). All mounting is listed in the pre-pass and after the interface PCHs; `CodegenMounts::freeze` then builds the layer once (PCH bytes as zero-copy views, wrapper texts copied once) and every TU shares it read-only, since `InMemoryFileSystem::addFile` is not thread-safe but its reads are. A TU pushes it through a proxy (`Native/KSharedVFS.hh`) that drops the one write it would otherwise make: `OverlayFileSystem::pushOverlay` copies the overlay's working directory into every layer it pushes, which on a shared layer is a `std::string` assigned from every worker at once (heap corruption in the suite before the proxy). `freeze` sets the layer's working directory once instead. A layer per TU cost about 2% of the fan-out's CPU: `addFile` hashes a file's whole contents into its UniqueID, about 50 MB of PCH per TU. Clang's "N errors generated." goes to `llvm::nulls()`.
3. **Post-pass, driver thread, TU order.** Each job's sink, then its `ctx->diag_sink`, is drained and its object pushed. Every TU runs even when one fails, so a build reports every TU's clang errors, and the same set and order whatever the worker count.

### Worker count

Workers are the pool size (`--threads`, default every logical CPU), capped at the number of TUs. `--codegen-threads=<n>` overrides it, for measurement. `--print-cg` and `--print-ir` force one worker, because they print as each TU fills.

There is no physical-core cap. On the small program, 23 SMT workers doubled each TU's time (total CPU 742 to 1507 ms) and stopped paying past about 12; on the 316-TU self-build, 24 workers beat 12 by 12% of the whole build. The large graph is the case that matters.

### Thread safety

`CodegenBackend::fill` runs Kairo code (`EmitPlan`, `EmitIR`, `InterfaceEmitter`, `TokenSink`) inside clang's `BeginSourceFileAction`, on the worker. The invariant that makes this safe: an emitter writes only its own TU's state (its plan, sink, `codegen_alloc`, `diag_sink`). Shared reads are of state Sema has finished: the AST, `InstantiationRegistry` (read under its shared lock), the imm tables, and the Kairo `SourceManager` (line tables, on the ICE path only). A new lazily computed cache on a shared node belongs in `prepare_shared`, never in `run()`.

Clang setup that is process-global stays serial and happens once: the driver probe, `CreateFromArgs`, `llvm::cl::ParseCommandLineOptions`, target initialization. The argv and its `StringSaver` are built once; workers get invocation copies.

### Runtime objects

The runtime's C objects (`_compile_runtime`) fan out the same way: invocations are built serially (`ClangBackend::native_invocation`; the argv arena and argument parser are shared), each `run_native` prints into its own log, and the logs are printed in input order after the join. The runtime build starts at the top of `FrontendAction::_sema` (`prestart_runtime`) so it overlaps Sema, and is joined after the batch's native compiles (`_join_runtime`). The runtime object cache is described in [Codegen.md](Codegen.md#pipeline).

### Profiling

`--time-passes` arms clang's profiler per worker thread (`Compiler/Native/KTimeClang.hh`). Rows from every worker land under `Codegen.Backend`; the driver's wait is `Backend.Join [idle]`. A TU's whole worker time is billed, in order:

| Row | What |
|---|---|
| `TUSetup` | the job's ClangLocMap, adapter and VFS; the invocation copy and `CompilerInstance`; clang's file and source managers, preprocessor and target before the fill |
| `Rebind`, `IRGeneration`, `TokenDrain` | the Kairo fill inside `BeginSourceFileAction`: fid registration, the emitters, handing the stream to the preprocessor |
| `PCHLoad` | from the fill's end to ParseAST: AST context and consumer, the implicit PCH (child `ReadAST`, clang's span), Sema, and `StartTranslationUnit` (child `SSALowering`: the IRGen of declarations the PCH marks as always emitted) |
| `Emission` (child `SSALowering`) | ParseAST: parse and Sema of the emitted C++, with the IRGen done decl by decl inside it |
| `SSALowering` | `HandleTranslationUnit`: deferred declarations, module finalization |
| `Optimize`, `MachineCode` | the optimizer pipeline, instruction selection through the object |
| `TUTeardown` | `EndSourceFile` freeing Sema and the AST, then the action (the LLVM module and context) and the instance |
| `ClangTrace [idle]` | the harvest itself: writing, freeing and scanning clang's trace |

Clang's scopes shorter than 50 µs keep only the profiler's per-name total; a dropped `Optimizer` / `CodeGenPasses` is billed from that total, and a dropped `CodeGen Function` stays in its parse row's self time (0.5% of that child row on the self-build). On the debug self-build the rows leave 0.5% of worker time untraced; before them, 67% was (most of it the trace lock).

Measured on the self-build (2026-11-07): per TU, `TUSetup` is about 0.3 ms and `PCHLoad` about 6 ms in release (`ReadAST` 2.9 ms of it). The PCH's real cost is demand deserialization inside `Emission` and `SSALowering`, as Sema and IRGen reach declarations. In a debug build `PCHLoad.SSALowering` was about 39 ms per TU: the `LLVM_DUMP_METHOD` (`used`) functions of the clang headers were IRGen'd in every TU, until build.py's debug profile defined `KAIRO_LLVM_DUMP_UNUSED`, which drops `used` in the merged PCH (`CodegenPCH::llvm_dump_prologue`).

### PCH layout

One merged PCH of every header set in the graph (`HeaderSetCache::codegen_pch`) is the implicit PCH of every TU; it is built on the pool while Sema runs (see [Codegen.md](Codegen.md#pipeline)). The codegen spike measured why:

- Textual re-parsing of the sets that were not the TU's PCH, `<coroutine>` above all, was about 28 of the 30 ms per small TU. Making the biggest set the PCH gave 4.7x; one merged PCH gave 8.1x, with no threads.
- Loading a PCH is cheap: an empty-body TU with the 1.45 MB merged PCH costs 1.6 ms; ASTReader is about 5% of the profile. The in-memory bytes are not re-read, and the reader deserializes lazily.
- A fresh `CompilerInstance` per TU costs the same as a reused one under the merged PCH. Per-worker startup is about 0.2 ms; memory is about +2 MB per worker.
- Chained PCHs load at the same cost as a flat one and are linear (each layer is built against the one below), so they cannot union independently built sets. They pay only at build time (a 4.5 ms layer over a cached base instead of a 48 ms full build). Not adopted.
- Sharing one `ASTReader` across TUs would mean sharing an `ASTContext` and `Sema` across TUs, breaking clang's `clearIDTables` model, to save about 1.5 ms per TU. Not adopted.

The [interface PCH](Codegen.md#the-interface-pch) is chained on the merged PCH: on the compiler's own graph it holds 1.0 M tokens (51 MB) of the 38 M the TUs used to stream, and each TU streams about 13 k. Its serial cost before the fan-out is about 2.5 s (plans 0.6 s on the pool, stream 0.4 s, clang parse and write 1.5 s); the fan-out went from about 19 s to 14.7 s and user CPU from 446 s to 359 s. What the fan-out spends now (flat profile): LLVM's optimizer and code generation at -O3, 54%; `ASTReader`, 13%; implicit instantiation of C++ templates the TUs' own bodies use (libc++ containers of Kairo types, about 31 CPU-s), once per TU that uses them.

Not implemented: an on-disk cache of the merged PCH keyed by the cc1 argv and the headers' paths, sizes and mtimes, which would build the builtin library's sets once per toolchain. A TU that loads the interface PCH loads the chain with validation off (`DisablePCHOrModuleValidation`); one that loads the merged PCH alone still validates it (no measurable difference on the self-compile).

One intermittent worker crash inside clang's `ASTReader` while instantiating a libc++ template from the shared PCH has been seen once and not reproduced.

## Parallel Sema

`FrontendAction::_sema_parallel` (`Compiler/Driver/FrontendAction.k`) runs Sema over the import groups ([Pipeline.md](Pipeline.md#compilation-phases)) on the compiler's `ThreadPool`. The result is the one-thread loop's to the byte: the objects of a self-build are identical with `--sema-threads=1` (the old loop, kept as the A/B baseline) and with the default, and across repeated runs.

### Schedule

Each group's Sema is cut in two:

1. **Front, on a pool worker.** I, E, V, N, T and the typed checks up to ConformanceChecking (`Sema::split_conformance`; an import cycle in lockstep, `sema_lockstep`). About 85% of Sema's time. A front starts once every group it imports has finished all of its Sema, because importers read the imported tree lowered.
2. **Rest, on the driver, in import order.** Conformance, the panic-set barrier, the late checks, the lowerings and mono, then the diagnostics drained into the engine, exactly as the one-thread loop does them. The driver runs a front itself when no worker has claimed it (`SemaSlot::run_front`).

A rest runs beside the fronts of later groups, which never import it. Three kinds of group run alone instead: with no front, after every earlier group, and with no front in flight (a barrier). These are groups whose Sema writes facts that TUs which do not import them still read:

| Barrier | Why |
|---|---|
| a builtin-subtree TU | N fills the lang items (`WellKnownDecls`, unlocked) that every TU reads |
| a TU declaring an explicit or partial specialization | the registry matches every use against them, imported or not (`register_partial` re-selects minted entries) |
| a TU declaring an extension | every TU's member lookup indexes every TU's extensions (`MemberLookup::index_extensions`) |

A front stops early in three cases, and the driver then finishes its group (`SemaSlot::partial`). In the first two the driver runs the group alone:

- after E, an `eval if` deferred to T's late fold, which decides from layouts (`EnumLayoutQuery::size_of`, `NullableType::lowered`) that other TUs' lowerings fill;
- after N, an out-of-line definition of a member of a type outside the group, which RedeclMerge splices into that file's redeclaration ring;
- after T, a once-per-build selection report (SC157E / SC158E). The front records it (`SemaContext::once_log`) instead of claiming its latch, because whichever front got there first would win. At the group's turn the driver claims it, before the rest (`FrontendAction::_settle_once`), and stops the file after T if it now has a T error (`Sema::stop_if_types_errored`). So the reporting file, and the file that stops, are the first in the one-thread order ([Diagnostics.md](Diagnostics.md#order-guarantee)).

On the compiler's own graph (276 groups) there are 27 barriers, all builtin TUs, and no stopped fronts.

### Order

Whatever runs first, everything observable follows the one-thread order:

- **Diagnostics** go into each TU's own `BufferedDiagSink` (no Sema pass reports to the engine) and are drained by the driver in group order.
- **InstantiationRegistry**: every request carries a key, the step of the one-thread schedule that asked (`sema_mint_rank`: the group's rank, narrowed by `sema_sub` to the lockstep phase and member) and the group's own request count (`sema_mint_counter`). Both are thread-locals the driver sets (`Native/KThread.hh`). An entry keeps the smallest key any request had and the home that request named (`_claim`); the worklist is kept sorted by key (`_insert_ordered`). A one-thread run's first request has the smallest key, so the worklist, `home_fid` and the M1 drain order are its. Requests outside any group (header indexing before Sema, codegen after it) key on a floor rank.
- **Foreign fills**: a fill records every registry request it makes on the shell's entry (`begin_fill`, `fill_reqs`). A TU earlier in the order that finds the shell already filled re-makes those requests (`rerequest`), as its own fill would have, unless the fill went through the filler's own header set and the TU's set differs.
- **`NullableType::seen_rank`**: NullableTypeLowering lowers every `T?` interned so far, build-wide; a TU lowers only those a one-thread run would have interned by then.
- **`InstanceEntry::formed_*`**, the panic set's anchor for the register-cliff remark: first in the order, not first in time (`note_formed`).

### Shared writers, audited

Arenas (`ArenaAllocator`, `ArenaList`) are single-owner, except a build-wide store's: its arena is `shared()` under a leaf mutex of its own (`_arena_mu`), which every `alloc()` takes. The store's own lock is not enough there, because its nodes carry `ArenaList`s bound to that arena (`dc_decls`, annotations, qualifier spans) and whoever grows one of those lists later does not hold the store's lock. Each cross-TU writer the fronts can reach, and what keeps it safe:

| Writer | Arena / storage | Rule |
|---|---|---|
| `InstantiationRegistry` (entries, rows, tables) | its own arena, shared under `_arena_mu` | `_mu` for the tables; order by key (above) |
| Instance shells' own lists (`dc_decls`, annotations; the shell's `dc_symbols`) | the registry's arena (the lists), the header TU's arena (the table, the imported members) | grown only by `ForeignInstantiate::fill`, under its `_mu`, never by the registry: so the arena's own lock, not `_mu`, is what keeps a fill's slab and a worker's new entry apart. Read after the shell's `ForeignFill` is seen `Filled` (an acquire load, `decl_instantiated`), or through `MemberLookup::ensure_filled`, which waits on the fill's `_mu` |
| `CanonicalTypeStore` | its own arena, shared under `_arena_mu` | `_mu`; identities are pure. `AssocType` bounds: the cycle guard is per TU (`SemaContext::assoc_busy`), the cache is published once after a release fence |
| `TupleRecords` | its own arena, shared under `_arena_mu` | `_mu`; interns `TupleN` into the builtin root's `ImmediateTable` |
| `ImmediateTable` identifier sheet | the table's `ArenaList`s | `_ident_mu`: writers exclusive (`intern_ident`, and the `synth_names` push of `intern_ident_copy` / `intern_string_copy` / `intern_bytes_copy`), `find_ident` shared. Writers into another TU's table: TupleRecords (root) and foreign fills (header TUs) |
| `ForeignInstantiate::fill` (header TU's DCs, shells, clang AST) | the header TU's arena | one build-wide `_mu`, then the set's `sema_lock`; the unlocked fast path reads the shell's `ForeignFill` with an acquire load; the fill writes it last, with a release store (`decl_publish_fill`) |
| `WellKnownDecls` | the global table | written by builtin TUs only, which are barriers |
| `MemberLookup::index_extensions` | per instance | reads every TU's declaration lists; skips a TU proven extension-free (`TranslationUnit::no_extensions`), whose lists its own Sema may be rewriting |
| `ClassLifecycle`, `CtorInitCheck` facts | the TU's own arena | own-TU decls only |
| `InterfaceComposition::compose` | the interface's TU's arena | only for an interface whose TU has not composed it, never an imported one |
| CallLowering `default_thunk` / `pack_type`, `EnumLayoutQuery::sweep`, `EffectTable`, `PanicInstances` | own TU / registry entries | rest only (driver thread) |

Known residuals, all on error paths or not reachable from the compiler's graph: which TU's sink gets clang's diagnostics for a fill, and whether a failed fill becomes sticky, follow the first demander; a lower-ranked TU whose header set could not have filled a shell may find it filled by a later TU; SC157E / SC158E (ambiguous or undecided partial) and R043E / R044E can be reported by a different TU when two TUs of no import relation name the same instance (the specialization's own TU is a barrier, so only uses race); `ClangDiagAdapter::_load_by_path` can load a file from a worker.

### Measurements

Debug compiler (`build.py --debug`), the compiler's own graph, `--type-check-only`, Sema loop wall on the driver (groups, barrier, lowerings, mono):

| Schedule | Sema wall |
|---|---|
| one thread (`--sema-threads=1`) | 28.5 s |
| fronts in parallel, rests alone | 23.5 s |
| rests beside later fronts | 20.5 s |
| import cycles as fronts (lockstep keys) | 19.0 s |

Whole debug self-build with `--time-passes`: 70.0 s one thread, 63.5 s parallel. What limits it is the in-order rest: a group's rest waits for its own front, and a front waits for its imports' rests, so a slow front delays every later group's rest. A dependency-only schedule of the same fronts and rests finishes in about 9.3 s; reaching it needs rests out of order, which first needs the late part's first-writer facts keyed like the registry's (`mark_live`'s `use_at` / `via`, `add_reach` order, row order and identity, `panic_checked`, the walk that reports an instance diagnostic). Fronts also run about 30% slower in parallel than alone (SMT siblings and shared caches); the `ImmediateTable` lock is not measurable. Neither are the shared arenas' leaf locks: a whole-tree debug type-check of the compiler, A/B against the same source without them, took 27.3 to 28.2 s against 27.7 to 29.3 s in parallel, and the Sema loop (the run less headers, preprocessing and parse) was 17.7 s parallel against 25.4 s on one thread either way.

## Compile-time optimizations

Each entry names the hot spot, the change, and the code that carries it. Output-preserving changes passed the byte-identical gate in [Benchmarks](#measurement-rules).

### Codegen planning

| Where | Change |
|---|---|
| `EmitPlan::_toposort` (`Compiler/Codegen/EmitPlan.k`) | Asks the edge matrix once (n²) and keeps a pending count per entry; it was n³ `_entry_needs` calls. The serial pre-pass went from 59 s to 16 s. |
| `EmitPlan::_needs_complete` | A `NeedRow` per declaration: the direct set (value-parameter classes, value-parameter template names, nested owners, folded from nested records) and the layout set (`LayoutSpine` in `collect` mode); `_set_at` indexes sets. `_type_names_vp` and `_names_vp_template`'s old bodies are dead code. |
| `TokenSink::_claim_for` (`Compiler/Codegen/Sink/TokenSink.k`) | `_claim_hint` maps an anchor to its known-used prefix, cleared on the one `_used.erase`. The claim walk follows shared, path-compressed skip pointers (`_next_free` past the anchor, `_next_unsettled` inside it). A file with one huge TU (`Registry.k`) went from 34 min to 8.4 s. |
| `FrontendAction::_codegen` | Candidates first, `prepare_shared` serially, then `_tu_is_empty` on the pool. |

### Header sets and PCH

| Where | Change |
|---|---|
| `CodegenPCH::build` (`Compiler/Interop/Clang/CodegenPCH.k`) | `PCHInstantiateTemplates = true`. Without it every TU re-performed the PCH's pending template instantiations: 659 s of 794 s of clang frontend CPU. The largest single gain (113 s to 79 s). |
| `HeaderSet::closure_of`, `kfid_of_path`, `closure_kfids` | Lazily built `StringMap`s (`_file_at`, `_out_edges`) instead of linear scans; `closure_kfids` is memoized per spelling and walks node numbers (`_node_of`, `_node_out`, `_node_path`). |
| `HeaderSetAction::CreateASTConsumer` | A plain `ASTConsumer`, no `PCHGenerator`: phase A builds no per-set PCH. The merged codegen PCH is built whenever the graph has any set. |
| `HeaderIndex::walk_declare` (`Compiler/Sema/Foreign/HeaderIndex.k`) | Skips a declaration whose target is frozen, unless the index is filling targets or the declaration is a namespace, linkage spec or export. |
| `HeaderSet::release` / `release_unused` | Header sets are freed when no longer needed: `DisableFree` is cleared before `EndSourceFile` (everything leaked before); `_sema` releases a set that contributed nothing after its last owning TU's group; `FrontendAction::run` releases all sets before codegen. `release_unused` snapshots macro names for `defined!`; a late use re-parses the set (`_revive`, diagnostics suppressed). `header_set_late_uses` and `header_set_revivals` count these. |
| `HeaderSet::build` | `SkipFunctionBodies = true` for phase A. `--type-check-only` therefore reports no errors inside header function bodies. |
| `HeaderSet::shared`, `HeaderSetCache::start_shared` | One header parse per build: each TU's header set is a view onto a shared union, resolved by normalized spelling. The self-build went from 39 s / 16 GB to 32 s / 10 GB. Ownership of header sets is in [Imports.md](Imports.md). |

### Sema

| Where | Change |
|---|---|
| `ffi_hide_tags` (`Compiler/AST/DeclFacts.k`) | Classifies tags once and pairs only tags with tags, with an early out when there are none; it was all-pairs over hundreds of `std` module declarations per `cxx::std::` step. |
| `MemberLookup::index_extensions` (`Compiler/Sema/Resolve/MemberLookup.k`) | Skips foreign (header) TUs. |
| `MemberLookup::_associated_scopes` | Deduplicates ADL scopes through a `DenseSet` seeded from the output, shared with `_enclosing_modules`. |

### Memory

| Where | Change |
|---|---|
| `ASTWriter::rebuild_*_list`, `rebuild_dc_decls` (`Compiler/AST/Visitor/ASTWriter.k`) | Copy on change: no buffer until an element maps to something else, then the unchanged prefix is seeded; untouched lists keep their array. Arenas after Sema went from 7.9 GB to 1.6 GB. |
| `ArenaAllocator::init_lazy` (`Compiler/Memory/ArenaAllocator.k`) | A default-constructed `ArenaList` allocates its first block on first use and logs nothing. |

### Driver, linker and threading

| Where | Change |
|---|---|
| `CompilerInstance::_start_runtime` / `_finish_runtime` | The runtime compile overlaps Sema (see [Runtime objects](#runtime-objects)). |
| `LinkJob::lto_cache_dir` (`Linker/API/LinkJob.k`, `Linker/API/Flavor/ELF.k`) | ELF links pass `--thinlto-cache-dir=<cache root>/lto` with a 4 GB size policy; the directory is created first and the option dropped if that fails. The vendored LLVM's lld archives are bitcode, so every link of the compiler ran ThinLTO over lld. Mach-O and COFF are not wired. |
| `TokenCacheManager` (`Compiler/Token/TokenCacheManager.k`) | `get_imm_table_for_token` reads a lock-free paged atomic mirror `fid -> ImmediateTable` (`_imm_dir`, published under `_lex_mu` by `_publish_imm`) instead of a `shared_mutex`. On musl most futex waits were that lock. |
| `GlobalDisambigTable` (`Compiler/AST/Context/GlobalDisambigTable.k`) | `get_context`, `get_scope`, `begin_index`, `is_builtin_fid` and `builtin_fid` read a lock-free paged atomic mirror `fid -> (ctx, hoisted, builtin)` (`_dir`, published under `_mu` by `_publish`) instead of taking the `shared_mutex`. `MemberLookup::index_extensions` calls `get_context` once per fid per lookup, so on musl that lock was most of a whole-tree check's kernel time (sys 10 s to 0.5 s). |
| `_sema_parallel` / the diagnostic flusher (`Compiler/Driver/FrontendAction.k`) | The driver and the flusher park on the slot's `done` flag with atomic wait (`PublishOnExit` notifies) instead of spinning on `sched_yield` (about 42k yields per whole-tree check). |
| `ThreadPool` (`Compiler/Threading/ThreadPool.k`) | Idle workers park on an atomic wait/notify (`_epoch`, `_sleepers`) instead of a mutex and condition variable, and no wake is issued while no worker sleeps. |

Rejected: preloading mimalloc into the compiler (126 s to 120 s at the cost of 7 GB more RSS).

The shared header parse was expected to be the route below 8 GB peak; with it the self-build peaks at about 10 GB.

### Container rules

Replacing a `libcxx::unordered_map` or `libcxx::deque` with an LLVM container is never mechanical. Each table is checked for:

| Rule | Requirement |
|---|---|
| Reserved keys | `DenseMapInfo<u64>` reserves `~0` (empty) and `~0 - 1` (tombstone). A table keyed by a hash (canonical types, `InstantiationRegistry`, anything hashing canonicals or USRs to `u64`) can produce them: an assertion in debug, silent corruption in release. Mask the hash or key by a wrapper. |
| Reference stability | `unordered_map` keeps value addresses across rehash; `DenseMap` does not. A table that hands out `&table[k]` or whose values are pointed into uses `DenseMap<K, T*>` with `T` in a `SpecificBumpPtrAllocator<T>`. The same allocator replaces every `deque` kept only for stable addresses. |
| Iteration order | `DenseMap` order is not stable across runs. A table iterated to emit code, order diagnostics, or build witness or explicit-instantiation lists is a `MapVector` / `SetVector`, so class text is identical in every TU. |
| Key traits | `u64`, pointers, `StringRef` and `std::pair` have `DenseMapInfo`. A Kairo record key would need a C++ specialization, so it is packed into a `u64` or re-keyed by pointer. |
| String keys | USRs and other string keys go in `llvm::StringMap` (owns its key bytes, looks up by `StringRef`), never a C++ map keyed by Kairo `string`. |

### Concurrency rule for lazy indexes

A pool task never indexes a container that the enqueuing side can resize. `SourceLineTable` builds a file's line index on the pool in two halves (`Compiler/Location/SourceLineTable.k`): `reserve_build` runs on the caller's thread under `SourceManager::_load_mu`, before the task is enqueued, and resolves the file's entry and increments `_builds`; `run_reserved_build` runs on the pool, fills that entry, and releases the reservation. Resolving the entry inside the task raced with `register_file` resizing the table and handed a worker a null buffer; counting the build only when the task started let `_drain_builds` return and `evict` unmap bytes a queued task still viewed. Every reservation must reach exactly one `run_reserved_build`. A consumer that reads line and column for a just-loaded file waits for the index (`wait_for_line_index`).

Each entry's build state is one atomic byte, `LineEntryState`: Absent (registered, never claimed), Queued (`reserve_build` claimed it), Building (a scan is filling it), Ready (lines published), Stale (`invalidate` withdrew the old index and rebuilds it under `_load_mu`). A claim is a compare-and-swap from Absent or Stale, so a second claim on an in-flight build fails instead of building twice; Queued and Building are always counted in `_builds`, so after a drain no entry may be in either, and a debug build asserts each transition's source state. `wait_until_ready` returns at once for an Absent entry, which nothing will build.

The lex workers of the preprocessor walk read the `VirtualFileManager`'s segment table unlocked, so nothing may register or re-map a file while a walk runs. `PreProcessor::preprocess` brackets the walk with `SourceManager::begin_walk` / `end_walk`; in a debug build an `invalidate`, `replace_bytes`, `evict` or `reset` inside the bracket is an ICE, and a registration is logged as a warning. The walk does still register files (an import that resolves to a file the dependency scan did not load, such as the sibling file R068E reports), so that check is not yet fatal.
