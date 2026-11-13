# ksys: on-demand sysroot construction

Apple's SDK and Microsoft's MSVC / Windows SDK are never shipped or generated. On macOS the installed SDK is used, on Windows the installed MSVC / Windows SDK, and cross-compiling to either needs a user-supplied SDK (`--sysroot`, or `--input` to `ksys`). Every other target's sysroot is generated on demand by `--target`. The user-facing docs describe this at a high level; this page is the detailed description.

## 0. Conventions

New diagnostic codes go in `Compiler/Diagnostic/TableGen/*.diag.toml`, with the `L001` / `U001` placeholders until a real code is assigned. Every error has a message, a `first()` label and a note, and a fix-it where there is an obvious edit.

## 1. What it is

`ksys` builds a sysroot for a target name from the release's `share/kairo/sysroot/` input tree, with no network, using only kcc, kld and the llvm-ar family. The driver calls it when `--target T` is given without `--sysroot` and no sysroot for T is installed or cached.

The generator is a library, `Linker/Sysroot/`, as the linker is `Linker/API/`. `ksys` (`Linker/Sysroot/Driver/ksys.k`) is a thin standalone binary over it for running it by hand, as `kld` is over the linker library. The kairo driver links the library and calls its `ensure` in-process; it never spawns `ksys`. The share tree's format is the contract with its producer, `Scripts/ship_sysroot_inputs.py`.

Non-goals: downloading anything; prebuilt sysroots beyond the host's own roots in `<install>/sysroot/`; Microsoft / Apple SDK handling beyond `--input`.

## 2. Names

Two fields, kept apart everywhere:

- name:          `armv7-linux-musl`, `x86_64-linux-gnu-glibc2.31`, `wasm32-wasi` (dir name, TOML `triple`, what --target matches)
- clang_triple:  `armv7-unknown-linux-musleabihf`, `x86_64-unknown-linux-gnu` (every --target= passed to kcc)

Grammar: `<arch>-<os>[-<env>][-glibc<ver>]`, vendor dropped except BSD names keep `unknown`. The family recipe gives `clang_triple` as a template; quirks may rewrite it. `ksys` accepts either form on the command line; a clang triple is normalised in-process through `llvm::Triple` and mapped to a name. Ambiguous input is an error that lists the candidates. SYSROOT.toml carries `clang_triple`, and `Toolchain.k` reads it.

Any well-formed triple names a target, not only the section 14 table (`Linker/Sysroot/Names.k`). The table is matched first (exact name, triple via `same_target`, prefix completion). A triple the table lacks gets its family from `llvm::Triple`'s OS and environment (linux + musl / gnu / none, windows + gnu / msvc, freebsd, netbsd, wasi, darwin), its arch spelled as the triple spells it, and its name and clang triple from `SysNames::make`. 32-bit Arm on Linux is always eabihf; a soft-float `musleabi` / `gnueabi` is refused, since names carry no float ABI; an unknown Linux environment is refused. Only macOS (darwin / macosx OS) is the darwin family. A glibc version is `-glibc<X.Y>` (canonical, in the name) or Zig's `<...>-gnu<env>.<X.Y>` (`x86_64-linux-gnu.2.17` is `x86_64-linux-gnu-glibc2.17`); `SysNames::split_glibc` separates it from the triple.

Whether a target can be built is asked afterwards, each refusal with its own P009E: the backend (the TargetRegistry in-process; there is no backend list), the provider (`<family> has no port for <arch>`: the recipe's `arches`) and the runtimes template's domain. A recipe `clang_triple` template left with an unexpanded `{per_arch.*}` does not replace the built-in triple.

`SysNames::properties(t)` is the twin of `props_of()` in `Scripts/runtimes_template.py`: libc, os, objfmt, bits, int128, cpu, rt_arch (compiler-rt's builtins arch), float, crt_arch, endian, arch, plus the descriptive threads (posix / win32 / none) and exceptions (dwarf / seh / arm-ehabi / none). The arch rules cover powerpc, systemz, mips, loongarch and sparc as well (sparc64 is compiler-rt's `sparcv9`). `ksys probe` prints them as one `properties:` row after `tools:`, with `backend=<TargetRegistry name>`.

## 3. Inputs (shipped tree)

`<install>/share/kairo/sysroot/`: registry.toml  runtimes/  runtimes-template/ (or runtimes-recipe/)  licenses/  families/  quirks.toml  shims/  validate/  musl/  linux-uapi/  glibc/  mingw/  mingw-crt/  freebsd/  netbsd/  wasi/  wasi-libc/. The producer, `Scripts/ship_sysroot_inputs.py`, writes it; its layout is the contract. `registry.toml` lists every input dir with `tree_sha256`; `ksys verify-share` recomputes them. `runtimes/REVISION` must equal the revision embedded in the compiler (`kairo --print-runtimes-revision`, and the same from `ksys --print-runtimes-revision`); a mismatch is a refusal.

The share tree's location is `--share`, else `$KAIRO_SYSROOT_SHARE`, else `<prefix>/share/kairo/sysroot`; the path is made absolute so `-ffile-prefix-map` rewrites it.

`registry.toml` declares `schema = 1` or `2`; the reader refuses anything else. Under schema 2, `SysUtil::tree_sha256` and `tree_stamp` never follow a link, and a link below an input root is a refusal naming it (`verify-share` prints `ERROR <key>`); the input root itself may be a link. Every provider copies an input subdir through `StageCtx::materialise` (`SysRun::materialise`): the files, then each `links.tsv` row under it as the same symlink (on Windows, or where a link fails, a copy of what the row resolves to inside the input), then each `casefold.tsv` row renamed back, or its `.kcase` dropped when the destination folds case (probed in the destination). A ksys that reads only schema 1 refuses a schema 2 share.

## 4. Pipeline

parse -> probe -> inputs -> libc-headers -> builtins -> libc-libs -> runtimes -> assemble -> toml -> validate -> cache

Each stage has its own key (section 7) and its own dir under the cache; a stage is skipped when its key dir exists and holds `.ok`. Stage dirs are written to `<dir>.tmp` and renamed on success; a failed stage leaves a `.failed` dir with `log/` and is retried next time. Each stage writes its product under `<stage dir>/out/` and reads earlier ones' through `StageCtx::product`; `StageCtx` also carries the recipe, the matched quirks and the toolchain dir. Recipes keep every key they were read with (`SysRecipe::str / flag / list / keys_of`), so later stages need no new fields.

### 4.1 parse

Resolve name, family recipe, arch, clang_triple, libc_version (glibc: `--glibc=X.Y`, default from `glibc/VERSIONS.toml`; must be in `versions` and >= `floor`), quirk set (section 6), provider.

### 4.2 probe

- backend: the arch's LLVM target is compiled into libLLVM (the TargetRegistry is queried in-process; llc is never spawned).
- int128: derived from the triple as clang's TargetInfo decides it (64-bit pointers, or wasm); feeds the `int128` predicate.
- quirk matching, and the `assert_compiles` entries a quirk lists.
- provider.supports(arch): recipe `arches` contains it; `host_only` matches the host; `user` providers have a valid `--input` (marker file present).
- tools: kcc and kld beside the binary, then on PATH.

Every probe failure is a refusal (section 9). `ksys probe T` runs this stage alone and prints a table.

### 4.3 inputs

Resolve the recipe's `inputs` (templates: {arch}, {libc_version}, {os_version}) to share-tree dirs; verify each against registry.toml `tree_sha256` (the verification is memoised by name, size and mtime under `<cache>/verify/`). A missing dir or hash mismatch is a refusal naming the dir. `runtimes` and `runtimes-recipe` / `runtimes-template` are inputs of every target whose recipe lists C++ runtimes, and of any other (wasi) when registry.toml lists them.

### 4.4 libc-headers  (provider stage 1)

- musl:   `make install-headers` restated in `Providers/Musl.k`: `include/`, then `arch/generic/bits` and `arch/<a>/bits` over `include/bits`, the generated `bits/alltypes.h` (from `tools/mkalltypes.sed`) and `bits/syscall.h` (from `syscall.h.in`), then the kernel UAPI from `linux-uapi/` named by the recipe's `[libc] uapi` (`linux-uapi/generic`, then `linux-uapi/asm/<uapi_arch>/asm`). `[per_arch.musl_arch]` and `[per_arch.uapi_arch]` map arches to musl's and the kernel's names (x32 uses `asm/x86_64`). The UAPI sets for powerpc, s390, mips, loongarch and sparc come from `make headers_install` of a Linux source tree (`ship_sysroot_inputs.py --linux-src`); a shared file is byte-identical to `generic/` except the few the curated set carries in its own form.
- glibc:  the shipped headers verbatim; UAPI is copied only when `include/linux/version.h` is absent.
- mingw:  `mingw/include`, one set for every arch.
- bundle: the input's `include/` to `bundle_layout.include` (freebsd: `usr/include`) and `lib/` to `bundle_layout.lib`, symlinks kept.
- wasi:   the `wasi/<v>` base per `[bundle_layout]` (libc++ `eh/` `noeh/`, `lib/wasm32-wasi/llvm-lto`) plus the wasi-libc table's `[headers]`.
- user:   msvc: the splat staged to `msvc/` (headers for every arch, libs for this arch, symlinks kept for case). darwin: the SDK staged without `c++/`, `libc++*.tbd` and `swift`. See "SDK families" in section 8.

### 4.5 builtins

compiler-rt builtins from the share's `runtimes/` source, with no CMake or ninja: `Linker/Sysroot/Runtimes.k` (`SysRuntimes`) compiles each source with `ctx->kcc(<sysroot>)` and writes each archive in-process. The tables are in `runtimes-recipe/` (one per target: `targets/<name>.toml` and one table per runtime) or are instantiated from `runtimes-template/` (section 4.7). The stage compiles only the `builtins` runtime and archives it to `<out>/<builtins_name>`. Darwin uses a subset: the listed sources (sets `@NAME` expand from `runtimes/compiler-rt/lib/builtins/sources.toml`) compiled and archived in libtool-darwin mode. Then the quirk `post_archive` (msvc aliases: a shim compiled with the same flags, merged by `kar` in lib mode). The required-symbols check (base_required_symbols plus the quirk's required_symbols defined `T` in the archive, read with llvm::object in-process) is specified here and is not implemented.

### 4.6 libc-libs  (provider stage 2)

- musl:   musl's Makefile source selection and compile rules, run as a parallel kcc loop: every `src/*/<a>/*.[csS]` replaces the generic `src/*/*.c` of the same stem, `libc.a` holds the `src/` and `compat/` objects (all `-fPIC`), crt objects get `-DCRT`, the NOSSP list gets `-fno-stack-protector`. The flag sets are what musl's configure decides for kcc (the same on every arch; only ARCH and SUBARCH differ), so neither make nor configure runs. `libc.a` is written in-process (`LinkFS::write_archive`); the crt objects (`crt1.o`, `Scrt1.o`, `rcrt1.o`, `crti.o`, `crtn.o`) and the empty libraries follow. No dangling `libc.so` symlink is produced. Clang's default ABIs are the ones musl's configure accepts (ppc64 ELFv2, ppc long double = double, mips o32 / n64 hard-float, loongarch64 lp64d, x32 ILP32), so no per-arch cc_define exists.
- glibc:  stub DSOs from the ABI lists: for each `<lib>.abilist`, one `.S` per soname with `.symver` for every symbol whose version node is <= X.Y (default `@@` on the newest such node), `.type @object` and `.size` from the abilist `D 0x<size>`, `@tls_object` for TLS, functions as a `ret`-only body. Assembled with kcc and linked with `kld -flavor gnu -shared -soname <soname> --version-script <nodes>`, never a kcc link step (which would inject the Kairo runtime). Sonames: libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libutil.so.1 libanl.so.1 libresolv.so.2 libcrypt.so.1 and the dynamic loader (name from `include/gnu/lib-names.h` `LD_SO`). glibc before 2.34 gets the `lib<x>-<v>.so` plus SONAME link layout; `libc.so` and `libm.so` are linker scripts (`GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( <ld.so> ) )`), with the dev links beside them (from 2.34 libpthread, libdl and librt are near-empty but still produced so `-lpthread -ldl` resolve). The crt objects and `libc_nonshared.a` are compiled from the sources in `glibc/crt/*` tables. No absolute paths appear anywhere.
- mingw:  with the `mingw-crt` input (`inputs = ["mingw", "mingw-crt"]`), the whole mingw-w64-crt is built from source: `Linker/Sysroot/CrtTable.k` (`SysCrtTable`) reads `mingw-crt/<arch>.toml`, which replays the crt's own Makefile (every `[def.*]` through `kcc -E -P -x c`, then `strip_at`, every source compiled, every `[group.*]` entry, one `SysJobs` window). Import libraries come from LLVM's dlltool driver in-process; members merge with `llvm-ar qc`, and `qcL` for the Makefile's MRI `addlib`. The files mingw-w64-crt does not build (winpthreads, libssp, winstorecompat, windowsappcompat, libomp's import library) come verbatim from `mingw/crt/<arch>`, then `[install]` lays files into `lib/`. Without `mingw-crt`, import libraries are rebuilt from `mingw/def/<arch>/*.def` and `mingw/crt/<arch>` is the rest of `lib/`.
- wasi:   `Providers/Wasi.k` builds from the wasi-libc table: `{sysroot}` from `[headers]`, SYSROOT.toml and the builtins archive; the compiles; GNU archives in-process; `empty` archives; every `[link.*]` with `kld -flavor wasm`; `[install]` into `{sysroot}` after the archives and after each link. `lib/` is the product.
- bundle / user: nothing.

### 4.7 runtimes

The `crt`, `libunwind`, `libcxxabi` and `libcxx` runtimes of the tables, in one window of compiles, after `build/<key>.toml` is laid into `<stage>/work/build` (`{build}`). `SysRuntimes` ports `Scripts/build_runtimes_direct.py` step for step: per-target table; the build tree; every source of the stage's runtimes (no runtime needs another's objects, only headers); each archive written in table order with a symbol table, deterministically, in-process (`LinkFS::write_archive_as`; COFF format for COFF triples; members named by basename, as llvm-ar does); the crt objects copied to `<out>/crt/`; `headers/<key>.toml` installed as the `include/c++/v1` tree. Every `[layout]` gather item is looked up in the table at its root path; a table archive that no gather item takes is a failure, not a silent drop. The products keep the generic stage contract, so assemble maps them through `[layout]` unchanged.

- Compiles: `ctx->kcc(<sysroot>)` plus `[flags].<lang>` plus the group flags (`{src}`, `{build}`, `{sysroot}`, `{share}` filled) plus `-ffile-prefix-map=<src>=kairo-runtimes -ffile-prefix-map=<work>=kairo-work`, through `SysJobs`. `ksys -j N` / `--jobs N` (else `$KSYS_JOBS`, else the hardware thread count) bounds the compiles in flight. A failed compile is P010E with its first error line and the log in the note.
- The `--sysroot` of every compile is `<stage>/work/sysroot`: the libc-headers product's include dirs that SYSROOT.toml names (outermost first, no `c++/` dir at any depth; wasi's `eh/` `noeh/` too) plus the target's rendered SYSROOT.toml. The table's `clang_triple` must equal the target's after the quirks; otherwise the target is refused, since the tables carry the quirk flags of the triple they were derived for, and the quirks' `cflags_add` are not applied again.
- Nothing comes from the host: every compile is `-nostdlibinc -nostdinc++` against the staged sysroot.
- For glibc the runtimes are compiled against the requested version's headers.

**Runtimes template** (`Linker/Sysroot/Template.k` `SysTemplate`; the share's `runtimes-template/`). `Scripts/runtimes_template.py` derives it from the `runtimes-recipe/` tables. Per sequence (a runtime's flags for one language, a group-flag profile, an archive's member list) the per-target sequences are merged by progressive LCS into one supersequence; a run of nodes present on the same targets is a fragment, and its `when` is the conjunction over properties (DNF if none fits) with the fewest excluded values that holds on exactly those targets. The script writes the template and re-instantiates every input target from the written files, failing on any difference. When `registry.toml` lists `runtimes-template`, `plan()` takes it as an input, refuses an out-of-domain target before any stage, and the builtins and runtimes stages instantiate it into `<stage>/work/tables` in the runtimes-recipe layout (`SysRuntimes::from_template`); `build/` and `headers/` come from the template's per-family copies. Without it the tables are used as shipped, and `plan()` refuses a target that has no `runtimes-recipe/targets/<name>.toml` before any stage runs. `ksys tables <target> --out DIR` writes the tables a target compiles from, unbuilt.

The template serves the targets it was derived from plus new combinations of their property values, best effort: a target whose rt_arch, libc or cpu it was not derived over (thumbv7em, a `none` OS) is refused (`fits()`), not guessed. Builtins needs compiler-rt's per-arch source lists, which only a table for that arch carries. The input tables are fixed up before derivation (printed by the script): armv6 hard-float builtins get `-DCOMPILER_RT_ARMHF_TARGET`, since CMake's list omits armv6 and every float- or double-returning builtin would otherwise use the soft-float pcs; riscv32 musl builtins get compiler-rt's `atomic.c`, since libc++ needs `__atomic_*_8` and musl has no libatomic. aarch64_be and thumbv7 musl parse and have backends but are refused at the provider unless the musl recipe lists them. Not supported: a no-threads variant (libc++'s `__config_site` comes from the family's headers tree, one per family) and bare metal.

### 4.8 assemble

Lays out `<sysroots>/<key>/` per family, per the recipe's `[layout]` (gather items mapped from install paths):

- musl / glibc: `include/` (headers + `c++/v1`), `lib/` (libc, crt, runtimes archives), `compiler-rt/lib/<clang_triple>/{builtins, crtbegin, crtend}`.
- windows-gnu: `include/`, `lib/` (crt + import libs + libc++.a + libunwind.a), `compiler-rt/lib/windows/libclang_rt.builtins-<rt_arch>.a`.
- bsd: `usr/include`, `usr/lib` (bundle), `libcxx/{include/c++/v1,lib}`, `compiler-rt/lib/<os_dir>/libclang_rt.builtins-<arch>.a`.
- wasi: the bundle as is, plus `compiler-rt/lib/wasm32-unknown-wasi/`.
- msvc: `include/c++/v1`, `lib/libc++.lib`, `compiler-rt/lib/windows/`, `msvc/` (local_only).
- darwin: the SDK layout, `usr/include/c++/v1`, `usr/lib/libc++.a`, `clang/lib/darwin/libclang_rt.osx.a`.

It asserts `__config_site` sits beside the headers (quirk `assert_file_contains`) and copies `LICENSES/<component>/` per input plus the runtimes (section 15). The assembled root is published by hard-linking it into `sysroots/<key>.tmp` with SYSROOT.toml and `.kairo-sysroot.json`, then renaming into place (`--out DIR` the same, without `.ok`).

### 4.9 toml

SYSROOT.toml is the recipe's `[toml]` rendered by the format rule only, byte-identical to the curated roots, so that the TOML keeps parity; `SysRecipe::render_toml` renders it. The extra facts go in `.kairo-sysroot.json`: the key object, every stage key, the quirk ids applied, the input tree hashes, the license ids copied, `clang_triple` and `generated_by = "ksys <kairo version> <compiler build id>"`. Key order and formatting are fixed so two builds of the same key produce byte-identical files.

### 4.10 validate

`ksys validate DIR` runs the same checks. In order; any failure deletes the sysroot dir (keeps `log/`) and exits 3:

1. structure: the manifest and the dirs it names.
2. proof the toolchain builds against the root: `kcc -###`. A bundled `<prefix>/sysroot/<name>` would shadow `--sysroot`, so that case is a refusal.
3. `validate/t.c` and `t.cpp` built from the TOML alone (with the TOML's `extra_cflags`), and `test.k`, `floats.k` and `tfbf.k` built with the manifest's own triple.
4. run per the recipe's `[validate].run`: native-or-qemu (host arch matches: run; else `qemu-<arch>` on PATH: run, musl binaries being static; else SKIP); native-or-qemu-with-root (as above, qemu needs `KAIRO_QEMU_ROOT_<arch>` for `-L`; else SKIP); wine-if-present; wasmtime-or-node-if-present (node first for wasm); native-if-host; link-only (never run). Every cpu=arm arch runs under `qemu-arm`; PowerPC spells `qemu-ppc*`; x32 runs natively. Exit codes come from `validate/expect.toml`. `[types]` there names the float types a program spells, and validate SKIPs a program where a probe compile says the target lacks one. SKIP is printed, never a pass.

### 4.11 cache

Root: `$KAIRO_SYSROOT_CACHE`, else `<toolchain cache root>/sysroot` (Driver.md's `$KAIRO_CACHE_DIR` / `$XDG_CACHE_HOME/kairo` / `~/.cache/kairo` / `%LOCALAPPDATA%/kairo`).

```text
stage/<stage>-<key>/     one dir per stage key, `.ok` inside
sysroots/<key>/          finished sysroots
by-name/<name>           -> ../sysroots/<key>
locks/<key>.lock         flock; concurrent builds of one key wait
verify/<sha(dir)>        tree_sha256 verification memo
build-id                 compiler_build_id memo
```

`by-name/<name>` is rewritten atomically after validate. Where a symlink cannot be made (Windows without the privilege) it is a one-line file holding the key, and lookup reads both. `ls`, `gc` (drops unlinked keys and stage dirs older than 30 days), `rm <name>`.

## 5. Providers

```text
interface SysrootProvider {
  fn id() -> string                      // "musl" | "glibc" | "mingw" | "wasi" | "bundle" | "user"
  fn supports(t: &Target, r: &Recipe) -> Support      // Ok | Refuse(reason)
  fn headers(ctx: &StageCtx, dst: &Path)
  fn libs(ctx: &StageCtx, dst: &Path)
  fn key_extra(t: &Target) -> [string]   // anything else that must enter the cache key
}
```

Providers never run the runtimes stages; 4.5 and 4.7 are generic and read the recipe. One file per provider under `Linker/Sysroot/Providers/`; `SysNames::provider_of` maps a family to its provider. The `user` provider (msvc, darwin) refuses on `plan()`: those families are staged by `SysSdk` (section 8) instead.

## 6. Quirks

Load `quirks.toml`; validate the schema on load (unknown key = error naming the quirk id). Match on parsed target components (arch, cpu: `match_cpu`, the arch's `Names.k` `cpu_of`; family, os, env) + probe results. Effects: target_rewrite (at most one match, else error), cflags{stages,add,add_cxx}, cmake{stages,defs}, force_include{stages,file}, post_archive, required_symbols, assert_file_contains, assert_compiles, musl_arch. Applied quirk ids are recorded in `.kairo-sysroot.json` and printed by `probe`. `assert_compiles` entries are matched and keyed but never compiled.

The shipped quirks include atomics-in-builtins-32 (musl and glibc powerpc / mips / mipsel: no 8-byte lock-free atomics and no libatomic, so compiler-rt's `atomic.c`; the Kairo runtime's mimalloc needs `__atomic_load_8`), x32-libunwind-narrowing (LLVM's libunwind narrows a u64 `link_reg_t` into x32's u32 `pint_t` in an init-list, so `-Wno-c++11-narrowing`), sparc64-as-sparcv9 (glibc: `target_rewrite`, since compiler-rt names the arch sparcv9 and, with `DEFAULT_TARGET_ONLY`, reads it off the triple) and armv7-musl-hardfloat (`match_cpu = ["arm"]`).

## 7. Keys

key = sha256 of canonical JSON {schema:1, name, clang_triple, provider, libc_version, input tree_sha256s, runtimes_revision, compiler_build_id, quirks: resolved effects for this stage only, tool_version}. `SysCache::key_schema()` is the `schema` field, written by both key builders (`Generator`'s `_key_json` and `Sdk`'s `_key`); a bump re-keys every root. compiler_build_id is a sha256 over kairo, kcc, kld, llvm-ar and `ksys` beside the binaries (memoised by path + size + mtime in `build-id`), computed once per process, so kairo's hook and ksys key a target alike. The runtimes stage for glibc uses libc_version = floor.

## 8. CLI and driver hook

```text
ksys probe    <target>
ksys ensure   <target> [--glibc=X.Y] [--input DIR]      # path on stdout, logs on stderr
ksys build    <target> [...] [--libc-only] --out DIR    # uncached; --libc-only: libc stages only
ksys tables   <target> --out DIR                         # the runtimes tables, unbuilt
ksys validate <dir>
ksys verify-share
ksys ls | gc | rm <name>
```

Global options: `--share DIR`, `--cache DIR`, `-j N` / `--jobs N`, `-q`; also `--help`, `--version`, `--print-runtimes-revision`. Exit codes: 0 ok; 1 usage; 2 refusal (reason on stderr, one line, actionable); 3 build or validate failure (stage, log path). A refusal is P009E (+ P009N), a build failure P010E.

Driver: `--target T`, or the implicit host target, without `--sysroot` (`CompilerSetup._sysroot_from_generator`):

  1. `<install>/sysroot/<name>`
  2. `<cache>/by-name/<name>`
  3. ensure (stderr: "building sysroot for <name>, first time only"); `--no-sysroot-build` turns step 3 into refusal 2. `Toolchain.k` rejects a TOML whose `triple` != name.

Step 3 is the library's `SysGen.ensure`, in-process. An explicit `--sysroot` skips steps 2 and 3, as do `--freestanding` and `--macos-sdk`. The cache lookup runs before the "Apple / MSVC target on a host without its SDK" P008E, so a root staged by hand (`ksys ensure --input`) serves any host; with no cached root, such a target stays P008E, whose note names `<prefix>/scripts/darwin-sysroot.sh` / `msvc-sysroot.sh`. Step 3 runs only when a share tree is present (`$KAIRO_SYSROOT_SHARE`, else `<prefix>/share/kairo/sysroot`); without one the driver keeps P008W, since there is nothing to build from. `--no-sysroot-build` is the refusal either way. The build is skipped for `--help`, `--version`, `--explain` and the info queries. `--version` reports a cached root (step 2) but never builds.

**Canonical `--target`** (`CompilerSetup._canonical_target`, first in `_apply_invocation`): a glibc version is split off by `SysNames::split_glibc` into `TargetOptions::glibc`, so clang, the env macro and the link see the plain triple; `_sysroot_target` puts it back as the root's name, and the bundled lookup matches that name exactly (a plain `x86_64-linux-gnu` still finds the bundled 2.31 by spelling). A macOS triple with no OS version gets the deployment floor (`Toolchain::with_os_floor`: 11.0 arm64 / arm64e, 10.15 x86_64), since clang's default has no TLS. FreeBSD / NetBSD / Linux / Windows / wasm triples are left as spelled. On 32-bit Arm the native default treats a plain gnu / musl environment as hard-float, as `canonical_triple` does for `--target`.

### SDK families

`Linker/Sysroot/Sdk.k` (`SysSdk`) builds the roots for darwin and windows-msvc; `SysGen.ensure` dispatches those families to it before `plan()`, and the driver does not require a share tree for them. It is a Kairo port of the fast path of `scripts/darwin-sysroot.sh` / `scripts/msvc-sysroot` (stage the SDK, lay `share/kairo/sdk-overlays/<darwin|msvc>-<arch>` over it, write SYSROOT.toml, check, validate), into the sysroot cache like a generated root. The overlay dir is `<prefix>/share/kairo/sdk-overlays`, else `sdk-overlays` beside the share tree.

- darwin: the SDK is `--input`, else (macOS hosts only) `Toolchain::find_sdk("macos")` (SDKROOT, DEVELOPER_DIR, the xcode-select link, the Command Line Tools, Xcode.app), else `xcrun --sdk macosx --show-sdk-path` when developer tools are selected. Staged as the script's stage_sdk does (Apple's `c++/` headers, `libc++*.tbd`, `swift/` and swift module files left out; files hard-linked where possible). SYSROOT.toml has no `clang_triple`: the driver puts a root's `clang_triple` in place of the user's `--target`, which would turn a spelled `arm64-apple-macosx13.0` into the floor.
- msvc: the splat is `--input`, else `$XWIN`, else `$MSVC_CACHE` or `<prefix>/share/kairo/msvc-cache` `/splat`. With none, on a Windows host with Visual Studio's C++ tools (vswhere), ksys runs `scripts/msvc-sysroot.ps1 <arch>` with its output in the cache (the VS + Windows Kits layout is read by the script's PowerShell half). With neither: P009E naming the exact `powershell -ExecutionPolicy Bypass -File <prefix>/scripts/msvc-sysroot.ps1 <arch>` command; the splat is a licensed download and is never fetched silently.
- No overlay (arm64e, an archive without overlays): a refusal naming the script's `--from-source` build (cmake + ninja).
- Key: name, the SDK's real path and SDKSettings.json hash (a splat: path and `sdk/include/um` stamp), the overlay's REVISION and stamp, the toolchain version. A later `ensure` with nothing to stage from reuses the by-name root.
- Validate: the structural checks of the scripts, then `kcc -c` of their C++ program against the root (compile only: the link would build the Kairo library inside the first use); skipped when a bundled `<prefix>/sysroot/<name>` would shadow `--sysroot`.

`ksys probe` and `build` for darwin and msvc go through `plan()` and the user provider's refusal. The xcrun, vswhere and PowerShell branches run only on a real Mac or Windows host.

## 9. Refusals (exit 2), exact wording owned by TableGen

- backend <X> not compiled into this toolchain
- runtimes/REVISION <a> does not match the compiler (<b>); reinstall the toolchain
- <family> has no port for <arch>
- glibc <v> is below the floor <floor> / not in the shipped set <list>
- <provider> needs --input DIR (<user_input>); marker <file> not found
- darwin sysroots can only be built on a macOS host
- share input <path> missing / tree hash mismatch (registry.toml)
- no runtimes-recipe table for the target, or a target outside the runtimes template's domain
- stage <s> failed: <first error line> (log: <path>)
- validation failed at <step>: <detail> (log: <path>)

## 10. Tests  (Tests/CLI/Sysroot/)

- parse/: name<->triple round trips, ambiguous input, every family name.
- probe/: refusal text for a fake unsupported arch; quirk application table.
- toml/: for each prebuilt sysroot, `ksys build` output TOML diffed against the curated one.
- build/: x86_64-linux-musl and x86_64-linux-gnu-glibc2.31 built from the share tree, validated, and the three .k programs run.
- cache/: second ensure is a no-op; a changed quirk file rebuilds only the stages whose effects changed; concurrent ensure waits.
- hook/: `--target x86_64-linux-musl` without --sysroot finds the installed root; with a fake name and --no-sysroot-build gives refusal 2.

## 11. Limits

- Not implemented: the builtins required-symbols check (4.5) and `post_archive` (msvc only).
- glibc runtimes are compiled against the requested version's headers, not the floor's.
- A toolchain whose `<prefix>/sysroot/<target>` exists still compiles the runtimes against that root: kcc prefers it over `--sysroot`.
- The copy fallback for links and case-insensitive casefold handling (section 3) are exercised only on filesystems that need them.
- The darwin and msvc paths are unit-tested off-host only (`ksys ensure --input`, `Tests/CLI/Sysroot/sdk_stage.k`).

## 12. Shipped roots

The host's own prebuilt roots ship in `<install>/sysroot/<name>/`, the layout step 1 of section 8 searches; which ones is `HOST_ROOTS` in `Scripts/package_release.py`, with a `manifest.json` naming just those. A hand-unzipped macOS, FreeBSD or NetBSD archive ships no root for its own host, so its first plain compile builds one through step 3. Every other target is built by `ksys` from `share/kairo/sysroot/`, which ships beside them.

- Apple and MSVC roots are never packaged. `Scripts/package_release.py` (`redistributable()`) excludes them by family (any SYSROOT.toml with `family` darwin / msvc, or `redistributable = false`), not by name, and the packaging smoke test fails if such a file is in an archive.
- `--target` naming an Apple or MSVC triple with no SDK on the host and no `--sysroot` is a refusal (P008E). On a macOS host the driver stages the installed SDK (`xcrun --show-sdk-path`), on Windows the installed MSVC / Windows SDK.
- The driver never fetches anything. `manifest.json` is a packaging input, validated offline by `Scripts/check_manifest_urls.py --offline`.

## 13. Tools

The generator spawns neither `clang` nor `ld.lld`: compiles go through kcc, links through `kld` (`-flavor gnu` / `wasm`), and archives are written in-process or by llvm-ar's alias links. The release ships kairo, kcc, kld, kfmt, kals, ksys, llvm-symbolizer and the llvm-ar family (`llvm-ranlib`, `llvm-lib`); `llvm-dlltool` and `llvm-libtool-darwin` are not shipped, and the dlltool driver runs in-process from libLLVM. `kcc --version` prints `installed version: kcc-<v>`, not `clang version`; a check that greps it for "clang" is wrong, and tools identify the compiler through `__clang__` of a test compile.

## 14. Targets

| name | provider | runs in validation |
| --- | --- | --- |
| x86_64-, aarch64-, armv7-, i686-, riscv64-linux-musl; armv6-, riscv32-, aarch64_be-, thumbv7-linux-musl | musl | native-or-qemu |
| powerpc-, powerpc64-, powerpc64le-, s390x-, mips-, mipsel-, mips64-, mips64el-, loongarch64-linux-musl; x86_64-linux-muslx32 | musl | qemu; x32 native |
| x86_64-, aarch64-, i686-, riscv64-linux-gnu-glibc2.31, armv7-linux-gnueabihf-glibc2.31 | glibc | native-or-qemu-with-root |
| other glibc arches (loongarch64, s390x, powerpc, mips, sparc64; newest version 2.42) | glibc | link-only |
| x86_64-, aarch64-, i686-, armv7-windows-gnu | mingw | wine-if-present |
| x86_64-unknown-freebsd, aarch64-unknown-freebsd, x86_64-unknown-netbsd | bundle | link-only |
| wasm32-wasi | wasi | wasmtime-or-node-if-present |
| x86_64-, aarch64-, i686-windows-msvc | user | native-if-host |
| x86_64-, arm64-, arm64e-apple-macosx | user (host-only) | native-if-host |

`riscv32-linux-musl` is the first target with no prebuilt root, and is the acceptance case for "a sysroot from a name alone". The glibc arches beyond the five shipped ones have gaps: powerpc stops at `Lib/rt/fmt_float.c` (IBM long double); mips and sparc64 at kcc's dynamic-linker table; gnux32 has no crt table. The Kairo library does not link for x32 musl, though C and C++ do.

## 15. Licensing of generated sysroots

A generated sysroot is something the user may redistribute (inside a container image, for example), so it carries its own notices:

- Assemble (4.8) copies `<share>/licenses/<component>/` into `<root>/LICENSES/` for every input it used: musl (MIT), Linux UAPI (GPL-2.0 WITH Linux-syscall-note), glibc stubs (LGPL-2.1+: the stubs are generated from abilists, and the notice still applies to the headers), mingw-w64 (its COPYING set), FreeBSD / NetBSD base (BSD), wasi-libc (its LICENSE set), compiler-rt / libc++ / libc++abi / libunwind (Apache-2.0 WITH LLVM-exception).
- `.kairo-sysroot.json` lists the license ids it copied. Validation (4.10) fails if an input in the key has no license entry. This is the same rule the release packaging enforces for the shipped tree.
- `user`-provider roots (Apple, MSVC) get no LICENSES copy and are marked in SYSROOT.toml, Apple ones `redistributable = false` and MSVC ones `local_only = ["msvc"]`; `Scripts/package_release.py` (`redistributable()`) refuses to ship either. The compiler does not read these keys (nor `msvc_crt`, which only records the static CRT). `ksys` never puts them anywhere but the local cache.

**glibc start files.** glibc's own sources for `crt1.o` / `Scrt1.o` / `crti.o` / `crtn.o` / `libc_nonshared.a` are LGPL-2.1-or-later with a link exception, except a few that have none (NOTICE lists them). A distributed glibc program statically contains those objects, so Kairo ships its own files for exactly those paths: every start-code source in a glibc root is either glibc's with the exception or Kairo's (Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception).

- Mechanism. `Scripts/glibc-own/` holds the files; `ship_sysroot_inputs.py` (`glibc_own_overlay`, run at the end of the glibc step, or alone with `--only glibc-own`) copies each over `glibc/src/<era>/<path>`, so the compile tables (`glibc/crt/*`) and `Providers/Glibc.k` name the same relative paths. `glibc/src` is therefore a mixed input: its `registry.toml [licenses]` entry is `LGPL-2.1-or-later AND Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception`, and `licenses/glibc/` also carries Kairo's `LICENSE` and the exception text.
- Replaced: `csu/init.c` (`_IO_stdin_used`) and `csu/static-reloc.c` (an empty hidden `_dl_relocate_static_pie`) in all three eras; `sysdeps/aarch64/start.S` and `.../linux/aarch64/__read_tp.S` in eras 2.32 / 2.33 (start.S adapted from the 2.42 file, which has the exception, keeping its header); `sysdeps/generic/crti.S` and `crtn.S` (empty; riscv and loongarch). On every arch except aarch64 2.17 to 2.32 the built objects are byte-identical to glibc's; aarch64 era 2.32 `_start` gains `bti c` in `__wrap_main`, a CFI section and its symbol size (the 2.33 glibc shape).
- Dropped: powerpc (32-bit) `sysdeps/powerpc/powerpc32/ppc-mcount.S`. No replacement `_mcount` exists; the object leaves the powerpc tables and `libc_nonshared.a`, so `-pg` fails to link there with an undefined `_mcount`.
- Audit: `Scripts/audit_glibc_exception.py` walks every `[compile.*]` source and the `.c` / `.S` files they include; it does not audit headers (`sysdep.h` can expand into code).
- Registry: the `glibc/src` and `glibc/crt` hashes cover these files, so a share built before them does not match archives packaged after them.
