# ksys: on-demand sysroot construction

Status: spec, to implement after 0.2.0. Owner: Dhruvan. Revision 2 (2026-11-08): adds section 12 (what 0.2.0 ships before this exists), section 13 (assumptions checked against the tree), section 14 (target table) and section 15 (licensing of generated sysroots).

Release policy (0.2.0): Apple's SDK and Microsoft's MSVC / Windows SDK are never shipped or generated. On macOS the installed SDK is used (`xcrun --show-sdk-path`), on Windows the installed MSVC / Windows SDK, and cross-compiling to either needs a user-supplied SDK via `--sysroot` (the `user` provider below). Every other target's sysroot is generated on demand by `--target`. The user-facing docs describe this only at a high level; this specification is still being written and is the only detailed description.

## 0. Read first, do not guess

Before writing any code, read and list the external signatures you will call:

- Linker/API/SysrootManifest.k      (how SYSROOT.toml is read today; add keys, rename nothing)
- Linker/API/Toolchain.k            (how --sysroot / --target resolve; the triple-mismatch rejection)
- Driver/                           (flag parsing conventions, --help-hidden, U005W pattern)
- Linker/Driver/kld.k, kld_drivers.hh (flavor dispatch)
- the ktar API (archive extraction in-process)
- std process spawn, fs, path, sha256 (whatever Lib/std exposes; if sha256 is missing use LLVM's SHA256 through ffi, do not write one)
- Spec/Docs for diagnostics: new codes go in TableGen/*.diag.toml; use L001 / U001 placeholders until assigned; every error has message + first() + note
  - fix-it where obvious. Post the signature list in the PR description. Code written against guessed APIs is rejected.

Style: match surrounding files; comments say why, not what; no AI traces in code, comments or commits; no inline C++.

## 1. What it is

`ksys` builds a sysroot for a target name from the release's `share/kairo/sysroot/` input tree, with no network, using only kcc, kld, kar and (until phase 2) cmake + ninja. The driver calls it when `--target T` is given without `--sysroot` and no sysroot for T is installed or cached.

Shape (decided 2026-11-09, replacing a `kairo sysroot` subcommand): the generator is a library, `Linker/Sysroot/`, as the linker is `Linker/API/`. `ksys` (`Linker/Sysroot/Driver/ksys.k`) is a thin standalone binary over it for running it by hand, as `kld` is over the linker library. The kairo driver links the library and calls its `ensure` in-process; it never spawns `ksys`. The share tree's format is `build/sysroot-share/FORMAT.md` (the contract with the maintainer-side producer, `Scripts/ship_sysroot_inputs.py`).

Non-goals: downloading anything; monomorphic prebuilt sysroots beyond the two host roots in `<install>/sysroot/`; Microsoft / Apple SDK handling beyond `--input`.

## 2. Names

Two fields, kept apart everywhere:

- name:          `armv7-linux-musl`, `x86_64-linux-gnu-glibc2.31`, `wasm32-wasi` (dir name, TOML `triple`, what --target matches)
- clang_triple:  `armv7-unknown-linux-musleabihf`, `x86_64-unknown-linux-gnu` (every --target= passed to kcc/cmake)

Grammar: `<arch>-<os>[-<env>][-glibc<ver>]`, vendor dropped except BSD names keep `unknown` as today. The family recipe gives `clang_triple` as a template; quirks may rewrite it. `ksys` accepts either form on the command line; a clang triple is normalised in-process through `llvm::Triple` (what `kcc --target=X -print-target-triple` would print, without the spawn) and mapped to a name. Ambiguous input is an error that lists the candidates. SYSROOT.toml gains `clang_triple` (write now; read in Toolchain.k in the same change so Kairo stops deriving it).

## 3. Inputs (shipped tree)

`<install>/share/kairo/sysroot/`: registry.toml  runtimes/  families/  quirks.toml  shims/  validate/ musl/  linux-uapi/  glibc/<X.Y>/<arch>/  mingw/  freebsd/<v>/<arch>/ netbsd/<v>/<arch>/  wasi/<v>/ The maintainer side (kairo-sysroots `curate/ship.sh`) produces it; its layout is the contract. `registry.toml` lists every input dir with `tree_sha256`; `ksys verify-share` recomputes them. `runtimes/REVISION` must equal the revision embedded in the compiler (`kairo --print-runtimes-revision`, and the same from `ksys --print-runtimes-revision`); mismatch is a refusal.

## 4. Pipeline

parse -> probe -> inputs -> libc-headers -> builtins -> libc-libs -> runtimes -> assemble -> toml -> validate -> cache

Each stage has its own key (section 7) and its own dir under the cache; a stage is skipped when its key dir exists and holds `.ok`. Stage dirs are written to `<dir>.tmp` and renamed on success; a failed stage leaves a `.failed` dir with `log/` and is retried next time.

### 4.1 parse

Resolve name, family recipe, arch, clang_triple, libc_version (glibc: `--glibc=X.Y`, default from `glibc/VERSIONS.toml`; must be in `versions` and >= `floor`), quirk set (section 6), provider.

### 4.2 probe

- backend: the arch's LLVM target is compiled into libLLVM (query the TargetRegistry in-process; do not spawn llc).
- int128: `kcc --target=T -dM -E -x c /dev/null` contains __SIZEOF_INT128__ -> feeds the `int128` predicate.
- quirk `assert_compiles` entries (wasm bf16).
- provider.supports(arch): recipe `arches` contains it; `host_only` matches the host; `user` providers have a valid `--input` (marker file present).
- tools: kcc, kld, kar on PATH or beside `kairo`; cmake + ninja for any recipe whose `runtimes` list is non-empty. Every probe failure is a refusal (section 9). `ksys probe T` runs this stage alone and prints a table.

### 4.3 inputs

Resolve the recipe's `inputs` (templates: {arch}, {libc_version}, {os_version}) to share-tree dirs; verify each against registry.toml tree_sha256 (cache the verification by mtime+size per dir). Missing dir or hash mismatch = refusal naming the dir.

### 4.4 libc-headers  (provider stage 1)

- musl:   `make -C <stage> -f <share>/musl/Makefile srcdir=<share>/musl ARCH=<musl_arch> install-headers DESTDIR=<stage>/hdr prefix=/` plus UAPI: copy linux-uapi/generic then linux-uapi/asm/<arch>/asm into hdr/include. musl_arch: x86_64, i386, aarch64, arm, riscv64, riscv32 (quirk `musl_arch` overrides).
- glibc:  copy glibc/<X.Y>/<arch>/include, then UAPI as above (glibc's include already carries the UAPI it was configured with; UAPI copy is skipped if `include/linux/version.h` exists).
- mingw:  copy mingw/include/<arch>.
- bundle: copy the input's include/ to `bundle_layout.include` (freebsd: usr/include) and lib/ to `bundle_layout.lib`.
- user:   msvc: copy splat to `msvc/` as msvc.sh's stage_msvc does (headers for every arch, libs for this arch, cp -a to keep case symlinks). darwin: stage_sdk as darwin.sh (exclude c++/, libc++*.tbd, swift).

### 4.5 builtins

Standalone compiler-rt builtins CMake, exactly the invocation in build-builtins.sh / build-wasi-builtins.sh / build-bsd-runtimes.sh, parameterised by: clang_triple, sysname, sysroot=<stage>, driver (gnu|cl), quirk cflags/cmake for stage "builtins", `baremetal`, os_dir. CMAKE_C_COMPILER = kcc (or `kcc --driver-mode=cl` via CMAKE_C_COMPILER_ARG1), CMAKE_AR = kar, CMAKE_RANLIB = kar (ranlib mode), CMAKE_LINKER = kld (flavor by sysname), TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY. Darwin: `builtins-subset` instead: compile the listed sources with kcc (sets `@NAME` expand from runtimes/compiler-rt/lib/builtins/sources.toml) and archive with kar in libtool-darwin mode, as darwin.sh build_tf_builtins does. Then quirk `post_archive` (msvc aliases: compile shim with the same flags, `kar` in lib mode merges). Then the symbol check: base_required_symbols + quirk required_symbols are defined `T` in the archive, read with llvm::object in-process (no nm, no grep). msvc/darwin: accept a leading `_`.

### 4.6 libc-libs  (provider stage 2)

- musl:   `make -C <stage>/musl-build -f <share>/musl/Makefile srcdir=... ARCH=... CC="kcc --target=<clang_triple>" AR=kar RANLIB="kar --ranlib" CFLAGS="-O2 -fPIC" lib/libc.a lib/crt1.o lib/Scrt1.o lib/rcrt1.o lib/crti.o lib/crtn.o` after running musl's `configure --target=<clang_triple> --disable-shared`. Install to <stage>/lib. Keep the dangling libc.so symlink out.
- glibc:  for each `<lib>.abilist` in the blob: soname table: libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libutil.so.1 libanl.so.1 libresolv.so.2 libcrypt.so.1 ld.abilist -> ld-linux-<arch>.so.<n> (name from include/gnu/lib-names.h LD_SO) emit one .S: `.symver` for every symbol whose version node
          <= X.Y, default (`@@`) on the newest such node; objects get
          .type @object and .size from the abilist `D 0x<size>`; TLS gets @tls_object; functions get a `ret`-only body. Assemble with kcc, link `kld -flavor gnu -shared -soname <soname> --version-script <nodes>` with no libs. Write libc.so as `GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( <ld.so> ) )`, libm.so / libpthread.so / libdl.so / librt.so as the scripts or symlinks glibc X.Y installs (from 2.34 libpthread/libdl/librt are near-empty; still produce them so `-lpthread -ldl` resolve). Copy crt/*.o and libc_nonshared.a. No absolute paths anywhere.
- mingw:  for every def/<arch>/*.def: `kar --dlltool -m <machine> -d X.def -l lib<X>.a` into <stage>/lib; copy crt/<arch>/* into lib/.
- bundle / user: nothing.

### 4.7 runtimes

One CMake configure of `<share>/runtimes/runtimes` with LLVM_ENABLE_RUNTIMES from the recipe (minus builtins, built in 4.5), the -D set from build-glibc-runtimes.sh / build-bsd-runtimes.sh / msvc.sh build_runtimes / darwin.sh build_libcxx, parameterised by cxx_abi (libcxxabi | vcruntime), static_only, cxx_hermetic, cxxabi_merged_into_cxx, sysname, quirk cflags/cmake/force_include for stage "runtimes". Compilers and archiver as in 4.5. For glibc, `runtimes_libc_version = "floor"`: this stage's sysroot is a libc stage built at the floor version (run 4.4 + 4.6 for the floor first); the stage key therefore excludes the requested version. Install to <stage>/rt-out; gather libc++.a, libc++abi.a, libunwind.a, libc++experimental.a, include/c++/v1, clang_rt.crtbegin*.o / crtend*.o when `crt` is in the list. Hard rule: nothing from the host (`-nostdlibinc -nostdinc++` on every compile, CMAKE_SYSROOT=<stage>, CMAKE_FIND_ROOT_PATH_MODE_* = ONLY).

### 4.8 assemble

Lay out `<sysroots>/<key>/` per family: musl/glibc:  include/ (hdr + c++/v1), lib/ (libc, crt, runtimes .a), compiler-rt/lib/<clang_triple>/{builtins, crtbegin, crtend} windows-gnu: include/, lib/ (crt + import libs + libc++.a + libunwind.a), compiler-rt/lib/windows/libclang_rt.builtins-<rt_arch>.a bsd:         usr/include, usr/lib (bundle), libcxx/{include/c++/v1,lib}, compiler-rt/lib/<os_dir>/libclang_rt.builtins-<arch>.a wasi:        bundle as is + compiler-rt/lib/wasm32-unknown-wasi/ msvc:        include/c++/v1, lib/libc++.lib, compiler-rt/lib/windows/, msvc/ (local_only) darwin:      SDK layout, usr/include/c++/v1, usr/lib/libc++.a, clang/lib/darwin/libclang_rt.osx.a Assert `__config_site` sits beside the headers; quirk `assert_file_contains`.

### 4.9 toml

SYSROOT.toml = recipe [toml] with templates filled ({xa} for msvc), plus: triple = <name>, clang_triple, llvm_version = "22.1.0", family, sysroot = ".", libc_version (musl/glibc), glibc_version (glibc, kept for compat), os_version (bsd), redistributable (darwin false), generated_by = "ksys <kairo version> <compiler build id>". Also `.kairo-sysroot.json`: the full key object + every stage key + quirk ids applied + input tree hashes. Key order and formatting fixed so two builds of the same key produce byte-identical TOML.

### 4.10 validate

In order; any failure deletes the sysroot dir (keeps log/) and exits 3:

1. required symbols (already checked in 4.5; recheck the installed archive).
2. replay: build validate/t.c and t.cpp from the TOML alone the way replay-validate.sh does (msvc: -idirafter for non-c++ dirs, cc_defines, -fms-runtime-lib=static, builtins via resource_dir; ELF: -resource-dir
   <root>/compiler-rt). Through kcc.
3. kairo: build validate/{test,floats,tfbf}.k with `kairo --sysroot <root> --target <name>` (requires cc_defines to be read by Kairo; do that first).
4. run per recipe [validate].run: native-or-qemu: host arch matches -> run; else qemu-<arch> on PATH -> run (musl binaries are static); else SKIP. native-or-qemu-with-root: as above but qemu needs KAIRO_QEMU_ROOT_<arch> for -L; else SKIP. wine-if-present / wasmtime-or-node-if-present / native-if-host: obvious. link-only: never run. Exit codes from validate/expect.toml. SKIP is printed, never a pass.

### 4.11 cache

Root: $KAIRO_SYSROOT_CACHE or ${XDG_CACHE_HOME:-~/.cache}/kairo/sysroot/. stage/<stage>-<key>/   sysroots/<key>/   by-name/<name> -> ../sysroots/<key> locks/<key>.lock (flock; concurrent builds of one key wait) `by-name/<name>` is rewritten atomically after validate. `ls`, `gc` (drop unlinked keys and stage dirs older than 30 days), `rm <name>`.

## 5. Providers

```text
interface SysrootProvider {
  fn id() -> string                      // "musl" | "glibc" | "mingw" | "bundle" | "user"
  fn supports(t: &Target, r: &Recipe) -> Support      // Ok | Refuse(reason)
  fn headers(ctx: &StageCtx, dst: &Path)
  fn libs(ctx: &StageCtx, dst: &Path)
  fn key_extra(t: &Target) -> [string]   // anything else that must enter the cache key
}
```

Providers never run CMake; stages 4.5 and 4.7 are generic and read the recipe. One file per provider under Linker/Sysroot/Providers/.

## 6. Quirks

Load `quirks.toml`; validate the schema on load (unknown key = error naming the quirk id). Match on parsed target components + probe results. Effects: target_rewrite (at most one match, else error), cflags{stages,add,add_cxx}, cmake{stages,defs}, force_include{stages,file}, post_archive, required_symbols, assert_file_contains, assert_compiles, musl_arch. Applied quirk ids are recorded in `.kairo-sysroot.json` and printed by `probe`.

## 7. Keys

key = sha256 of canonical JSON {schema:1, name, clang_triple, provider, libc_version, input tree_sha256s, runtimes_revision, compiler_build_id, quirks: resolved effects for this stage only, tool_version}. compiler_build_id = sha256 over kairo, kcc, kld, kar and every ldd-resolved library under the install (memoised by path+size+mtime), computed once per process. The runtimes stage for glibc uses libc_version = floor.

## 8. CLI and driver hook

```text
ksys probe    <target>
ksys ensure   <target> [--glibc=X.Y] [--input DIR]      # path on stdout, logs on stderr
ksys build    <target> [...] --out DIR                   # uncached
ksys validate <dir>
ksys verify-share
ksys ls | gc | rm <name>
```

Exit codes: 0 ok; 2 refusal (reason on stderr, one line, actionable); 3 build/validate failure (stage, log path).

Driver: `--target T` without `--sysroot`:

  1. <install>/sysroot/<name>
  2. <cache>/by-name/<name>
  3. ensure (stderr: "building sysroot for <name>, first time only") `--no-sysroot-build` turns step 3 into refusal 2. Toolchain.k keeps rejecting a TOML whose `triple` != name.

As built (step 6, `CompilerSetup._sysroot_from_generator`): step 3 is the library's `SysGen.ensure`, in-process. Steps 2-3 run only for an explicit `--target` with no `--sysroot`, `--freestanding` or `--macos-sdk`; Apple / MSVC targets on a host without their SDK stay P008E (its note names `<prefix>/scripts/darwin-sysroot.sh` / `msvc-sysroot.sh`). Step 3 runs only when a share tree is present (`$KAIRO_SYSROOT_SHARE`, else `<prefix>/share/kairo/sysroot`); without one the driver keeps P008W, since there is nothing to build from. `--no-sysroot-build` is the refusal either way. The build is skipped for `--help`, `--version`, `--explain` and the info queries. A refusal is P009E (+ P009N) and exit 2, a build failure P010E and exit 3. `--version` reports a cached root (step 2) but never builds.

The cache root is `$KAIRO_SYSROOT_CACHE`, else `<toolchain cache root>/sysroot` (Driver.md's `$KAIRO_CACHE_DIR` / `$XDG_CACHE_HOME/kairo` / `~/.cache/kairo` / `%LOCALAPPDATA%/kairo`). A `by-name` entry is a symlink; where one cannot be made (Windows without the privilege) it is a one-line file holding the key, and lookup reads both.

## 9. Refusals (exit 2), exact wording owned by TableGen

- backend <X> not compiled into this toolchain
- runtimes/REVISION <a> does not match the compiler (<b>); reinstall the toolchain
- <family> has no port for <arch>
- glibc <v> is below the floor <floor> / not in the shipped set <list>
- <provider> needs --input DIR (<user_input>); marker <file> not found
- darwin sysroots can only be built on a macOS host
- cmake / ninja not found (needed for the runtimes stage until it is built in)
- share input <path> missing / tree hash mismatch (registry.toml)
- stage <s> failed: <first error line> (log: <path>)
- validation failed at <step>: <detail> (log: <path>)

## 10. Tests  (Tests/CLI/Sysroot/)

- parse/: name<->triple round trips, ambiguous input, every family name.
- probe/: refusal text for a fake unsupported arch; quirk application table.
- toml/: for each of the 18 existing sysroots, `ksys build` output TOML diffed against the curated one (byte-identical except the added keys; glibc: include_dirs differs by the dropped multiarch dir - expected).
- build/: x86_64-linux-musl and x86_64-linux-gnu-glibc2.31 built from the share tree, validated, and the three .k programs run. Gated on cmake.
- cache/: second ensure is a no-op; a changed quirk file rebuilds only the stages whose effects changed; concurrent ensure waits.
- hook/: `--target x86_64-linux-musl` without --sysroot finds the installed root; with a fake name and --no-sysroot-build gives refusal 2.

## 11. Order of work

1. Toolchain.k: read `clang_triple` and `cc_defines`. Add `kairo --print-runtimes-revision`.
2. kar (ar/ranlib/lib/dlltool/libtool-darwin modes) and kld with zlib.
3. parse, probe, inputs, cache, keys, CLI skeleton, refusals.
4. bundle provider + builtins + runtimes + assemble + toml + validate: freebsd, netbsd, wasi, windows-gnu (mingw provider is libs-only; its headers stage is a copy). Acceptance: TOML parity with curated.
5. musl provider; acceptance as section 10 build/ plus riscv32 from a name.
6. driver hook.
7. glibc provider; acceptance: TOML parity modulo include_dirs, validate parity against the Ubuntu-derived roots at 2.31, then 2.28 and 2.35.
8. user provider: msvc, then darwin (host-only).
9. Phase 2: replace CMake in 4.5/4.7 with a kcc loop driven by runtimes/.../sources.toml and shipped __config_site per cxx_abi.
10. Delete curate/<family>.sh and build-*.sh per family as each passes.

Each step is its own PR. Do not start step N+1 while step N has failing tests.

## 12. 0.2.0: what ships before the generator exists

None of sections 1-11 is implemented in 0.2.0. Until step 6 (driver hook) lands, cross targets use prebuilt sysroots:

- The release ships the 18 redistributable prebuilt roots listed in `sysroot/manifest.json` (release `v1-llvm22`, LLVM 22.1.0), unpacked under `<install>/sysroot/<name>/`, exactly the layout the driver's step 1 (section 8) already searches. About 3.1 GB unpacked (the three BSD roots are half of it); the per-target `.tar.xz` assets total about 350 MB.
- Apple (`arm64-apple-macosx`, `arm64e-apple-macosx`, `x86_64-apple-macosx`) and MSVC (`aarch64-`, `i686-`, `x86_64-windows-msvc`) roots exist in a development `sysroot/` but are never packaged. `Scripts/package_release.py` must exclude them by family (any SYSROOT.toml with `family` darwin/msvc, or `redistributable = false`), not by name, and the packaging smoke test fails if any such file is in an archive.
- `--target` naming an Apple or MSVC triple without `--sysroot` is a refusal (exit 2 / a P-category diagnostic naming `--sysroot`): on a macOS host the driver uses `xcrun --show-sdk-path`, and on Windows the installed MSVC / Windows SDK. Elsewhere the user supplies the SDK.
- No network access, ever: the driver never fetches a manifest asset. `manifest.json` is a packaging input, validated offline by `Scripts/check_manifest_urls.py --offline`.
- `ksys` does not exist in 0.2.0. It must not appear in `--help` or the docs until step 3 lands.

When the generator lands (step 6), the prebuilt roots stop shipping one family at a time, as each family passes TOML parity (section 10 toml/) and validation. The release then ships `share/kairo/sysroot/` (section 3) instead, which is much smaller: no runtimes are prebuilt per target.

## 13. Assumptions checked against the tree (2026-11-08)

| Spec says | Tree has | Consequence |
| --- | --- | --- |
| `kar` (ar / ranlib / lib / dlltool / libtool-darwin modes) | no `kar`; the release ships `llvm-ar` plus its alias links `llvm-ranlib` and `llvm-lib` (`llvm-dlltool` is not shipped in 0.2.0: nothing links with it; the mingw provider (4.6) adds it back when it lands) | Until step 2 builds `kar`, every `kar` in sections 4.5-4.6 means `llvm-ar` in the matching alias mode. Darwin's libtool mode becomes `llvm-ar --format=darwin` plus `llvm-ranlib`; `llvm-libtool-darwin` is not shipped and is not to be added. |
| tools beside `kairo`: kcc, kld, kar | the release ships kairo, kcc, kld, kfmt, llvm-symbolizer, the llvm-ar family; no clang, clang++, lld or ld.lld binaries | CMake runs get `CMAKE_C_COMPILER=kcc`, `CMAKE_CXX_COMPILER=kcc` in C++ mode (`--driver-mode=g++`), and `CMAKE_LINKER=kld`. Nothing may spawn `clang` or `ld.lld` by name. |
| CMake identifies kcc as Clang | `kcc --version` prints `installed version: kcc-<v>`, not `clang version` | CMake's compiler-id step reads `__clang__` from a test compile, not `--version`, so detection works. Any check that greps `--version` for "clang" is a bug in that check. |
| "the 18 existing sysroots" (section 10) | 18 in `manifest.json`, plus 7 local Apple/MSVC dirs | Parity is against the 18. The 7 are `user`-provider outputs and have no curated twin to diff against. |
| curated inputs from kairo-sysroots | the `curate/` directory of the separate kairo-sysroots project holds `{musl,glibc,mingw,freebsd,netbsd,wasi,darwin,msvc}.sh`, `build-{builtins,wasi-builtins,glibc-runtimes,bsd-runtimes}.sh`, `ship-*.sh`, `replay-validate.sh`, `sources.toml` | These are the reference invocations sections 4.4-4.10 name. `ship.sh` producing `share/kairo/sysroot/` (section 3) does not exist yet: the `ship-*.sh` scripts are the starting point. |

## 14. Targets

| name | provider | step | runs in validation |
| --- | --- | --- | --- |
| x86_64-linux-musl, aarch64-linux-musl, armv7-linux-musl, i686-linux-musl, riscv64-linux-musl | musl | 5 | native-or-qemu |
| x86_64-, aarch64-, i686-, riscv64-linux-gnu-glibc2.31, armv7-linux-gnueabihf-glibc2.31 | glibc | 7 | native-or-qemu-with-root |
| x86_64-, aarch64-, i686-, armv7-windows-gnu | mingw | 4 | wine-if-present |
| x86_64-unknown-freebsd, aarch64-unknown-freebsd, x86_64-unknown-netbsd | bundle | 4 | link-only |
| wasm32-wasi | bundle | 4 | wasmtime-or-node-if-present |
| x86_64-, aarch64-, i686-windows-msvc | user | 8 | native-if-host |
| x86_64-, arm64-, arm64e-apple-macosx | user (host-only) | 8 | native-if-host |

`riscv32-linux-musl` (section 11 step 5) is the first target with no prebuilt root, and is the acceptance case for "a sysroot from a name alone".

## 15. Licensing of generated sysroots

A generated sysroot is something the user may redistribute (inside a container image, for example), so it carries its own notices:

- Assemble (4.8) copies `<share>/licenses/<component>/` into `<root>/LICENSES/` for every input it used: musl (MIT), Linux UAPI (GPL-2.0 WITH Linux-syscall-note), glibc stubs (LGPL-2.1+: the stubs are generated from abilists, and the notice still applies to the headers), mingw-w64 (its COPYING set), FreeBSD / NetBSD base (BSD), wasi-libc (its LICENSE set), compiler-rt / libc++ / libc++abi / libunwind (Apache-2.0 WITH LLVM-exception).
- `.kairo-sysroot.json` lists the license ids it copied. Validation (4.10) fails if an input in the key has no license entry. This is the same rule the release packaging enforces for the shipped tree.
- `user`-provider roots (Apple, MSVC) get no LICENSES copy and are marked `redistributable = false` in SYSROOT.toml. `ksys` never puts them anywhere but the local cache.

## 16. State after step 3 (2026-11-09)

Implemented: names (section 2, the section 14 table built in, recipes override `clang_triple`), parse, probe (backend through the TargetRegistry in-process; `int128` derived from the triple as clang's TargetInfo decides it, 64-bit pointers or wasm, rather than a `kcc -dM -E` spawn; quirk matching; provider support; tools beside the binary then PATH), inputs (registry `tree_sha256`, memoised by name + size + mtime under `<cache>/verify/`), keys (section 7; `compiler_build_id` covers kairo, kcc, kld, llvm-ar but not yet their ldd closure), the cache layout, `.tmp` / `.ok` / `.failed` stage dirs, flock'ed locks, `ls` / `gc` / `rm`, `verify-share`, the refusals (P009E/P009N, exit 2; P010E, exit 3), the driver hook (section 8). `validate` checks the manifest and the dirs it names and refuses the four build-and-run steps. Every provider stage refuses ("not implemented yet") and so do builtins, runtimes, assemble, toml and validate: ensure verifies, keys, locks and stops at libc-headers. Not done: `assert_compiles` quirks are matched and keyed but never compiled.

