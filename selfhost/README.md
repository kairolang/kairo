# selfhost/

The scratch pipeline of `private/SELFHOST.md` section 4: Stage 0 source at a
pinned `main` commit -> migration scripts -> patch series -> one phase of
section 5 with the Stage 1 compiler. The scratch tree is a build artifact;
never edit it, rerun the pipeline.

```
python3 selfhost/run.py                        # pin main's HEAD, phase syntax
python3 selfhost/run.py --commit <sha>         # pin another main commit
python3 selfhost/run.py --only Compiler/Lexer  # one directory, end to end
python3 selfhost/run.py --phase-only           # rerun the phase on the existing scratch
python3 selfhost/run.py --jobs 8 --timeout 180 # defaults
```

What a run does:

1. `selfhost/scratch/` becomes a detached, sparse `git worktree` of the pinned
   commit holding only `Compiler/`, `Linker/` and `Extras/KaTAR` (the `-I`
   roots of the section 3 build line). A previous one is removed with
   `git worktree remove --force`; an unregistered directory in its place
   stops the run rather than being deleted blind.
2. `Scripts/Migration/cast_facts.py` runs on the pristine scratch tree (cached
   as `logs/cast-facts-<commit>.json`; submodule and `build/llvm` trees it
   needs are symlinked in for that step only). Then
   `Scripts/Migration/migrate.py <scratch> --apply --with-libcxx --cast-facts
   ... --check-idempotent`. A pass that changes its own output stops the run.
3. The migrated tree is committed inside the scratch worktree (so that
   `git apply --3way`, which implies `--index`, sees a clean index), then
   `patches/*.patch` apply in order. A patch that fails stops the run and is
   named.
4. The phase runs and writes `logs/<phase>-<commit>.log` (human) and
   `logs/<phase>-<commit>.json` (per-file results, buckets, raw output).

`logs/pipeline-<commit>.log` has the full cast_facts / migrate / patch output.

## Phase `syntax` (5.1)

`kairo --syntax-only --error-format=basic --cmax-errors=0 -I Compiler -I
Linker -I Extras/KaTAR <file>` on every `.k` of the scratch tree, in parallel,
with a per-file timeout. The binary is the RELEASE Stage 1 (section 4.1 rule
5); its path, mtime, version and the newest `main` commit before its mtime are
recorded in the log, since the binary carries no commit of its own.

`--syntax-only` still resolves imports and macros, so each run also parses the
files the input imports. Diagnostics are attributed to the file they name and
deduplicated across runs. Buckets are keyed by code + message with quoted
text and numbers masked, and ranked by the number of files whose FIRST error
(by position) is in the bucket: later errors in a file may be recovery
cascades, so that count is the one a fix is sure to unblock.

A crash is a signal exit, an exit code other than 0/1, or an ICE marker in the
output (I957E, the error-limit note, excepted). A file reporting `file:0:0` is
rerun once alone first (a known line-index race).

## Patches

`patches/NNN-*.patch`, applied in name order. A hand fix is saved as the next
patch and the pipeline rerun; one that turns out to be mechanical becomes a
script in `Scripts/Migration/` and its patches are dropped. Compiler gaps are
fixed in `main`'s `Compiler/` by the gap agent, never patched here.

## Deviations from SELFHOST.md section 4

- `run.py`, not `run.fish`: tooling is Python so it runs on every host.
- No `selfhost/migrate/` copy of the scripts: the migrate step is
  `Scripts/Migration/migrate.py` (the pass manager, in its pipeline order), so
  a script fix lands once and both trees use it. `stub_ffi_imports` (a dry-run
  aid) is never enabled; `libcxx_to_cxx_std` is (`--with-libcxx`).
- The scratch tree is a sparse worktree rather than `rm -rf` + checkout, and
  includes `Extras/KaTAR`, the third `-I` root.
- `redundant_parens` runs in its default Stage 0-safe mode. The scratch tree
  is never compiled by Stage 0, so `--no-stage0-safe` would be legal; it is
  off until that is decided, since the safe output is valid Stage 1 too.

## gaps/

One minimal `.k` per Stage 1 parser gap the syntax phase found, each headed by
the failing command, the message, why the code should be valid (with the
Spec/Docs rule where there is one) and the self-host sites it blocks. They
are reports for the gap agent (SELFHOST.md 4.2), not tests: a fix lands in
`main` with its own regression test under `Tests/`.
