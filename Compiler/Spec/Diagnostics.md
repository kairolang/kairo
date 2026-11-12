# Diagnostics

Every message the compiler prints to a user goes through one engine (`Compiler/Diagnostic/Engine.k`) and carries a stable code defined in a TOML table. This document covers the code scheme, the registry generated from the tables, how a diagnostic is built and rendered, how clang's diagnostics are brought into the same scheme, and fix-its. The user-facing catalogue of messages is the language reference's *diagnostics* page.

## Codes

A code is `<category><number><severity>`, for example `SC041E`, `S003W`, `CL001F`, `OPT001R`.

| Category | Prefix | Covers | Table |
|---|---|---|---|
| Syntax | `S` | lexer, preprocessor tokens, parser | `Syntax.diag.toml` |
| Resolution | `R` | imports, macros, name resolution | `Resolution.diag.toml` |
| Semantic | `SC` | Sema checks and typing | `Semantic.diag.toml` |
| CodeGen | `C` | clang warning groups, generated ([Clang diagnostics](#clang-diagnostics)) | `Clang.diag.toml` |
| Lowering | `CL` | clang diagnostics without a warning group | `Lowering.diag.toml` |
| Memory | `M` | memory model and allocation | `Memory.diag.toml` |
| Linker | `L` | linking | `Linker.diag.toml` |
| Portability | `P` | targets, toolchain discovery | `Portability.diag.toml` |
| Optimization | `OPT` | optimization remarks | `Optimization.diag.toml` |
| Internal | `I` | internal compiler errors and engine notices | `Internal.diag.toml` |
| Uncategorized | `U` | not yet triaged; driver and flag errors | `Uncategorized.diag.toml` |

The category enum is `DiagCategory` (`Compiler/Diagnostic/Category.k`). The number is three digits for Kairo's own tables and four for the generated clang table; a printed code is zero-padded to at least three digits, so `C0195W` prints as `C195W`. `diag_from_code` (`Compiler/Diagnostic/Code.k`) accepts either spelling.

| Severity | Letter | Meaning |
|---|---|---|
| Ignored | `I` | Lowest severity. `-W <code>` raises an Ignored code to a warning. The engine does not drop it ([Engine](#engine)). |
| Remark | `R` | Informational, typically from optimization passes. |
| Verbose | `V` | Verbose-mode output. |
| Note | `N` | Attached to a parent diagnostic. |
| Debug | `D` | Debug-build output. |
| Warning | `W` | Compilation continues. |
| Error | `E` | The current unit fails. |
| Fatal | `F` | The compiler stops. |

`DiagSeverity` (`Compiler/Diagnostic/Severity.k`) orders them by impact as listed. One base code (`SC041`) can be defined at several severities (`SC041E`, `SC041W`); each is its own `DiagID` with its own explanation.

### Placeholders

Every hand-written category table defines `<prefix>001` as a placeholder at every severity, with the brief "place holder diagnostics". A new diagnostic with no matching code uses its category's placeholder (in practice `R001`, `SC001` and `U001`) rather than borrowing a real code whose message sounds similar; a code is only reused after its table entry has been checked to describe the same condition. Placeholders are periodically promoted to real codes with their own explanations. `CL001` is a placeholder that is also a permanent fallback: it carries every clang diagnostic that has no warning group.

`U` codes are a holding area: every diagnostic in `Uncategorized.diag.toml` is to be moved into a real category before a stable release.

### Reporting

A diagnostic is built with a `DiagBuilder`, obtained from `DiagEngine::report` or `BufferedDiagSink::report`:

```kairo
report(code: DiagCode | DiagID, loc: SourceLocation, msg: string) -> DiagBuilder
report(code: DiagCode | DiagID, msg: string) -> DiagBuilder   // no location
```

The builder's attach methods return `unsafe *Self`, so a chain continues with `->`:

```kairo
self.diag->report(DiagID::S055E, open.start, "...")
    .first(open | close, "empty panic set")
    ->remove(open | close, "remove the empty list")
    ->emit();
```

| Method | Attaches |
|---|---|
| `first(range, text)` | primary label (`^^^`) |
| `second(range, text)` | secondary label (`+++`) |
| `highlight(range, text)` | highlighted region (`---`) |
| `strike(range, text)` | struck-out region (`~~~`) |
| `fix`, `remove`, `insert` | fix-its ([Fix-its](#fix-its)) |
| `note`, `warning`, `remark`, `verbose`, `debug_note` | a child diagnostic, with or without a location; with an explicit `DiagCode`, or without one (children then use the reserved `I900` base, since a child is never emitted, counted or explained on its own) |
| `child_first`, `child_second`, `child_fix` | a label or fix-it on the most recent child |
| `emit()` | hands the diagnostic to the engine; idempotent |

`DiagBuilder` is move-only: the move constructor transfers ownership and copies are deleted. A builder destroyed without `emit()` is an ICE ("DiagBuilder dropped without emit()"); emission is never implicit, because an implicit emit at scope exit would escape suppression scopes such as the parser's `TentativeGuard`. When the engine would drop the code anyway (`DiagEngineVBase::drops`), the builder allocates nothing and every attach is a no-op.

An error reports its message, a `first()` label on the offending range, a `note()` at the relevant declaration where there is one, and a fix-it where the edit is obvious.

## Registry

The tables are `Compiler/Diagnostic/TableGen/*.diag.toml`, one per category. Each base code is a table:

```toml
[SC041]
brief = "return type mismatch"
group = "type-check"

    [SC041.E]
    explain = """
    # return type mismatch
    ...
    """
```

| Key | Content |
|---|---|
| `brief` | one-line summary, no final period |
| `group` | a group name, stored in `DiagMeta`; not used to select diagnostics (per-code flags take codes) |
| `<letter>` | one sub-table per severity defined for the code |
| `<letter>.explain` | Markdown long-form explanation shown by `--explain` |

An explanation has a `#` title matching the brief, a paragraph saying what went wrong and why, a `## Example` with one minimal failing case, and a `## How to fix`. A new code takes the next unused number in its table; numbers of removed diagnostics are never reused.

`Scripts/gen_diag.py` reads every `*.diag.toml` in the directory and rejects any key other than `brief`, `group` and the severity letters, a duplicate code, and two codes that differ only in zero padding (they would be one code to `--explain` and to the policy flags). It writes:

- `Compiler/Diagnostic/Registry.k`, the public interface: `enum DiagID` (each value is the hash of the code string), declarations of `diag_meta`, `diag_explain` and `diag_from_string`, and the module `Diag` with one function per category (`Diag::S(num, sev)`, `Diag::C(num, sev)`, ...) mapping a number and severity to a `DiagID`. It is generated: never edit it by hand.
- `TempRegistry.k`, the bodies, next to the object file; the script compiles it with the `kairo` on `PATH` into the object named by `--lib-output`.

```bash
python3 Scripts/gen_diag.py Compiler/Diagnostic/TableGen \
  --lib-output=build/.kbld/registry.o --output=Compiler/Diagnostic/Registry.k
```

`build.py`'s prebuild step runs exactly this ([BuildSystem.md](BuildSystem.md#buildpy)). The script skips work when a stamp next to the object matches a hash of the tables, the script itself, the `kairo` binary and its runtime headers. A link error naming `Diag` or `Registry` symbols means a stale object: delete `build/.kbld/registry.o` and rebuild. Self-hosted trees build their registry from the migrated source instead ([SelfHosting.md](SelfHosting.md#harness)).

`DiagCode` pairs a `DiagID` with its cached `DiagMeta` (brief, group, number, hash, category, severity). Two codes are equal when category, severity and number are equal.

### Explanations

`kairo --explain <CODE>` (`CompilerInstance::run_explain`) trims the argument, resolves it with `diag_from_code`, and renders the explanation's Markdown to the terminal (`TermRenderer`, 80 columns). An unknown code prints an error and exits 1.

## Rendering

### Engine

`DiagEngine::emit` is the single choke point; it holds a mutex because lexers and other pool workers report into it directly. A thread holding a `DiagCapture` puts what it reports into its own sink instead (see [Order guarantee](#order-guarantee)), which is drained here later. It applies, in order:

1. Suppression depth (`push_suppress`/`pop_suppress`): drop.
2. Duplicates: a located diagnostic whose code, location and message were already delivered is dropped. A file is tokenized twice ([Lexing.md](Lexing.md#streaming-interface)), and without this each lexer warning printed once per pass.
3. Poison scopes: an error or warning of a poisoned category inside the poisoned range is dropped. The API (`poison`, `clear_poison`) exists but no pass calls it, and `--diag-cascade` is registered as unimplemented.
4. Per-code policy, keyed on category and number (the severity letter is not part of the key, so `-A R020` and `-A R020E` are one entry, while `SC005` and `S005` are distinct). Precedence, highest first: `-F <code>` (force error, not overridable), `-E <code>` (warning to error), `-A <code>` (drop), then the blanket `-w` (drop all warnings) and `--Werror` (all warnings to errors). An explicit code beats a blanket flag. `-W <code>` raises an Ignored code to a warning and, given after `-A`, lifts that silence. Errors and fatals are never silenced.
5. `--quiet`: drop warnings, notes and remarks.
6. Warning limit (`--cmax-warnings`, 0 unlimited): past it, warnings are dropped and one U024W notice is printed.
7. Error limit (`--cmax-errors`, default 20, 0 unlimited): errors and fatals are counted first (`error_count`, `fatal_count`), then, past the limit of delivered ones, dropped, with one I957E notice. The limit caps what is shown, not what is counted: every stage gate reads the counters (a TU's own "did it error" delta, the batch abort on a fatal), so a TU whose errors are hidden still stops where it would have (P887).
8. The other counters, then trimming of children to `--cmax-notes` and of fix-its to `--cmax-suggestion-count` (default 5, 0 keeps none).
9. Delivery to every registered consumer.

`BufferedDiagSink` (`Compiler/Diagnostic/BufferedDiagSink.k`) is a per-file engine stand-in. The parser and a clang instance write into one; it supports suppression depth and the `@no_warn(CODE)` scopes registered by `AttributeCheck` (warnings only), and `drain_into` sorts its diagnostics by file, offset and insertion order before passing them to the engine. The driver drains parse sinks in file order, so parallel and serial runs print the same output.

#### Order guarantee

For a fixed input and fixed flags the compiler prints the same diagnostics in the same order on every run, at any thread count, and `--cmax-errors` cuts the same ones, because the engine applies the limit in delivery order and delivery order is fixed (P956). Every parallel phase buffers each file's diagnostics and hands them to the engine in an order that depends only on the input, each file's batch in source order:

- **Preprocessor walk.** The walk runs the import graph in waves, and the files of one wave walk side by side. Each walk task holds a `DiagCapture` (`Compiler/Diagnostic/Engine.k`, a thread-local set for the task). While it holds one, `DiagEngine::emit` puts whatever that thread reports, lexer included, into the task's own sink. When a wave is done, `WaveExecutor::run` drains its sinks in the wave's dispatch order. So waves come out in graph order, and within a wave the order is the ready list's. Each wave is drained as soon as it finishes, not at the end of the walk. The module-name collisions that the dependency scan finds are reported once, before the walk (`FileImportIndex::report_collisions`), rather than by whichever walk asks first.
- **Parse.** Each file's sink is drained in fid order, as soon as every earlier file has been drained (the flusher in `FrontendAction::_parse`).
- **Sema.** Each group's sinks are drained in import-group order (`_sema_finish`), whichever front finished first.
- **Codegen.** Each job's sinks are drained in TU order after the fan-out.

The output is byte-identical to the one-thread run's (`--threads=1`), with one known exception in an import cycle. On one thread, each member of the cycle runs its typed checks and then its Conformance before the next member starts. A front runs every member's typed checks first. So if one member uses an instance only unwritten and a later member names it in a body, a different member can report its selection. This predates the order guarantee.

A once-per-build report goes to the first file in the one-thread order. Today these are the partial-selection reports SC157E and SC158E, which T makes at the first written mention of an instance (`InstanceLatch::Ambiguity` / `Undecided`). A parallel Sema front does not take the latch. It records the mention (`SemaContext::once_log`) and stops after T. The driver then claims the mentions at that group's turn, in the order the front met them (`FrontendAction::_settle_once`). A claimed report is a T error, so it stops its file after T (`Sema::stop_if_types_errored`), exactly as it does in a one-thread run. `Scripts/diag_determinism.py` runs the compiler N times on an input and reports how many distinct outputs it got.

### Consumers

`DiagConsumer` (`Compiler/Diagnostic/Consumer.k`) receives each delivered diagnostic through `handle` and writes its buffer on `finalize_to_stderr`, `finalize_to_stdout`, `finalize_to_file` or `finalize_to_string`. `--error-format` selects one:

| Format | Consumer | Output |
|---|---|---|
| `pretty` (default) | `PrettyDiagConsumer` (`PrettyConsumer.k`) | colored header, `-->` location, source context with right-aligned line numbers, label rows, children, and a fix-it on the primary line rendered in place (removed text struck, inserted text marked) |
| `basic` | `BasicDiagConsumer` (`BasicConsumer.k`) | one line per diagnostic and per child: `file:line:col: severity [CODE]: message`, or `severity [CODE]: message` without a location; each ranged fix-it follows on its own line |
| `json` | `BasicDiagConsumer` with `set_json` | one JSON object per line with `file`, `line`, `col`, `severity`, `code`, `message` |

`msvc` and any other value are refused with U021E. Color is off with `--no-color`, when `NO_COLOR` is set, or when the stream is not a terminal. `--diag-absolute-paths` prints absolute paths; `--diag-show-context` and `--cmax-diag-context-lines` control the pretty consumer's source context. Codes are always printed; `--diag-show-ids` is accepted and does nothing.

## Clang diagnostics

Kairo hands generated C++ to an in-process clang ([Codegen.md](Codegen.md#diagnostics), [Interop.md](Interop.md#clang-integration)). `ClangDiagAdapter` (`Compiler/Diagnostic/ClangDiagAdapter.k`) is the `clang::DiagnosticConsumer` on each clang instance; it converts every clang diagnostic into a Kairo `Diagnostic` in the TU's `BufferedDiagSink`, so the consumers render them like any other.

Location. The clang location's expansion location (never the spelling location, which for literals is a scratch buffer) is decomposed into a clang file id and offset. The file id maps to a Kairo file id through the backend's `ClangLocMap`, a header set's own table, or by loading the file by path; because emitted C++ carries the Kairo source's bytes and offsets, the offset is used directly. A header set's synthesized `#include` lines map back to the `.k` import that wrote them. A location in no file Kairo knows is kept in the message text as `file:line:col:` and the diagnostic has no location.

Code. A diagnostic whose clang ID has a warning option (`-W<group>`) maps to `C<n>` with `n = clang_diag_number(group)`; one without maps to `CL001`. Severity maps directly, except that clang's Fatal becomes Error. An access error clang raises inside Kairo-emitted C++ is reported as I003E, a compiler bug: Kairo's own access check admitted the access.

Notes. Clang emits notes as separate calls after their primary; the adapter keeps the primary's builder open and attaches each following note as a child until the next primary or the end of the file.

### The clang code table

The `C` numbers are allocated once and never change:

| File | Role |
|---|---|
| `Compiler/Diagnostic/TableGen/ClangDiagCodes.toml` | the allocation manifest (`[groups."<name>"] number = N`), persistent; entries are never renumbered or reused, and a group clang no longer has is kept as `removed = true` |
| `Compiler/Diagnostic/TableGen/Clang.diag.toml` | generated table: one `C<nnnn>` per live group, at W, E, F and R |
| `Compiler/Diagnostic/ClangDiagLookup.k` | generated `clang_diag_number(group)`: a switch over the group name's hash |

`clang-diag-identity` (built by `build.py` from `Compiler/Tooling/GenClangDiagIdentity.k`) prints clang's warning groups. `Scripts/gen_clang_diag_table.py` reads them, allocates numbers for new groups, tombstones vanished ones, and writes the three files. It runs before `gen_diag.py`, since its output is one of `gen_diag.py`'s inputs:

```bash
./build/x86_64-linux-gnu/debug/bin/clang-diag-identity \
    | python3 Scripts/gen_clang_diag_table.py \
        --manifest Compiler/Diagnostic/TableGen/ClangDiagCodes.toml \
        --output Compiler/Diagnostic/TableGen/Clang.diag.toml \
        --lookup-output Compiler/Diagnostic/ClangDiagLookup.k
```

## Fix-its

A `FixIt` (`Compiler/Diagnostic/Diagnostic.k`) is a range, replacement text, a message, and a kind:

| Builder call | Kind | Edit |
|---|---|---|
| `fix(range, text, msg)` | `Replace` | replace `range` with `text` |
| `remove(range, msg)` | `Remove` | delete `range` |
| `insert(loc, text, msg)` | `Add` | insert `text` at `loc` |
| `fix(msg)` | none | a suggestion with no edit |
| `child_fix(range, text, msg)` | `Replace` | on the most recent child |

An invalid range or location makes the call a no-op. All fix-its of one diagnostic are one edit: a tool applies them together or not at all. A note's fix-it is an alternative, not the fix.

In `basic` format each ranged fix-it is printed after its diagnostic in clang's parseable form, 1-based, end exclusive, columns in bytes:

```text
file.k:3:14: error [S012E]: expected '=>' after the pattern
fix-it:"file.k":{3:14-3:16}:"=> "
```

`Scripts/apply_fixits.py` applies these to the source, from a fresh run or a saved log, skipping overlapping edits and applying duplicates once.

Clang's fix-its are edits to emitted C++, where most tokens borrow the location of the Kairo token they came from. `ClangDiagAdapter` therefore keeps a clang fix-it only when it removes or replaces exactly one token whose spelling in the emitted C++ equals the Kairo text at the mapped position, and never keeps an insertion. If any hint of a diagnostic fails that test, none are kept; the message is still reported. This adapter is the reference for the shape a fix-it must have to be safe to apply to Kairo source.
