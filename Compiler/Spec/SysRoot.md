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
  fn id() -> string                      // "musl" | "glibc" | "mingw" | "wasi" | "bundle" | "user"
  fn supports(t: &Target, r: &Recipe) -> Support      // Ok | Refuse(reason)
  fn headers(ctx: &StageCtx, dst: &Path)
  fn libs(ctx: &StageCtx, dst: &Path)
  fn key_extra(t: &Target) -> [string]   // anything else that must enter the cache key
}
```

Providers never run CMake; stages 4.5 and 4.7 are generic and read the recipe. One file per provider under Linker/Sysroot/Providers/.

## 6. Quirks

Load `quirks.toml`; validate the schema on load (unknown key = error naming the quirk id). Match on parsed target components (arch, cpu: `match_cpu`, the arch's Names.k cpu_of, since Z3; family, os, env) + probe results. Effects: target_rewrite (at most one match, else error), cflags{stages,add,add_cxx}, cmake{stages,defs}, force_include{stages,file}, post_archive, required_symbols, assert_file_contains, assert_compiles, musl_arch. Applied quirk ids are recorded in `.kairo-sysroot.json` and printed by `probe`.

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

As built (step 6, `CompilerSetup._sysroot_from_generator`; amended by section 22, which supersedes what follows where they differ): step 3 is the library's `SysGen.ensure`, in-process. Steps 2-3 run only for an explicit `--target` with no `--sysroot`, `--freestanding` or `--macos-sdk`; Apple / MSVC targets on a host without their SDK stay P008E (its note names `<prefix>/scripts/darwin-sysroot.sh` / `msvc-sysroot.sh`). Step 3 runs only when a share tree is present (`$KAIRO_SYSROOT_SHARE`, else `<prefix>/share/kairo/sysroot`); without one the driver keeps P008W, since there is nothing to build from. `--no-sysroot-build` is the refusal either way. The build is skipped for `--help`, `--version`, `--explain` and the info queries. A refusal is P009E (+ P009N) and exit 2, a build failure P010E and exit 3. `--version` reports a cached root (step 2) but never builds.

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
| powerpc-, powerpc64-, powerpc64le-, s390x-, mips-, mipsel-, mips64-, mips64el-, loongarch64-linux-musl; x86_64-linux-muslx32 (Z5, generic names; x32 Kairo link P702) | musl | Z5 | qemu; x32 native |
| x86_64-, aarch64-, i686-, riscv64-linux-gnu-glibc2.31, armv7-linux-gnueabihf-glibc2.31 | glibc | 7 | native-or-qemu-with-root |
| x86_64-, aarch64-, i686-, armv7-windows-gnu | mingw | 4 | wine-if-present |
| x86_64-unknown-freebsd, aarch64-unknown-freebsd, x86_64-unknown-netbsd | bundle | 4 | link-only |
| wasm32-wasi | wasi (bundle before Z3) | 4 | wasmtime-or-node-if-present |
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


## 17. State after wave B1 (2026-11-09)

Every stage runs. Each stage writes its product under `<stage dir>/out/` and reads earlier ones' through `StageCtx::product`; StageCtx also carries the recipe, the matched quirks and the toolchain dir. Recipes keep every key they were read with (`SysRecipe::str / flag / list / keys_of`), so later stages need no new fields.

- Providers. musl: install-headers restated (include/, the generated bits/alltypes.h and bits/syscall.h, arch/generic then arch/<A> bits; byte-identical to `make install-headers` on all five arches), the UAPI from `[libc] uapi`; libs: the Makefile's source selection and flags (configure's verdict for kcc, the same on every arch) as a parallel kcc loop, libc.a written in-process (LinkFS::write_archive), crt objects, the empty libraries. No make, configure or shell. glibc: headers verbatim (UAPI only without linux/version.h); stub DSOs from the abilists (kcc -c, then `kld -flavor gnu -shared`: a kcc link step injects the Kairo runtime, P591), glibc <2.34's lib<x>-<v>.so + SONAME link layout, the libc.so / libm.so scripts, dev links, armhf's ld-linux.so.3. mingw: headers; import libraries from the defs through llvm's dlltool driver in-process (byte-identical to the curated ones); crt/ verbatim. bundle: [bundle_layout] copied with symlinks kept. user: unchanged (refuses).
- builtins / runtimes: at B1, a copy from the bundled root of the same name (TODO(SYSROOT-RT), `KSYS_RT_FALLBACK`); replaced in wave B3, section 18.
- assemble per [layout] (gather items mapped from install paths), LICENSES/<component>/ per input plus runtimes, the __config_site and assert_file_contains checks. toml: [toml] rendered by the FORMAT rule only, byte-identical to all 18 curated roots; the 4.9 additions go in `.kairo-sysroot.json` (key object, stage keys, quirks, inputs, licenses, clang_triple, generated_by) instead, so the TOML keeps parity. validate (also `ksys validate DIR`): structure, then a `kcc -###` proof that the toolchain builds against the root (a bundled `<prefix>/sysroot/<name>` shadows --sysroot: refusal), then t.c / t.cpp (with the TOML's extra_cflags, P590) and test.k / floats.k / tfbf.k built with the manifest's own triple and run per [validate] run (qemu-<arch>, KAIRO_QEMU_ROOT_<arch> for glibc, node first for wasm, wine), exit codes from expect.toml; SKIP printed, never a pass. Not done: the required-symbols archive check (builtins stage's, with B2). Publish: the assembled root hard-linked into `sysroots/<key>.tmp` with SYSROOT.toml and `.kairo-sysroot.json`, renamed into place (`--out DIR` the same, without `.ok`).
- compiler_build_id also covers ksys beside the binaries, so kairo's hook and ksys key a target alike.

## 18. State after wave B3 (2026-11-09)

builtins and runtimes compile. `Linker/Sysroot/Runtimes.k` (`SysRuntimes`) is a port of `Scripts/build_runtimes_direct.py` over the `runtimes-recipe/` tables (build/sysroot-share/FORMAT.md, "runtimes-recipe"): no CMake, ninja or llvm-ar is run, and the TODO(SYSROOT-RT) copy from a bundled root and `KSYS_RT_FALLBACK` are gone. Sections 4.5 and 4.7 above describe the CMake design the tables were derived from (`Scripts/runtimes_recipe.py`); this is what runs.

- Inputs and keys. `runtimes` and `runtimes-recipe` are inputs of every target whose recipe lists C++ runtimes, and of any other (wasi) when registry.toml lists them; both are tree-hashed like every input, so the tables' hash is in every stage key and the sysroot key. `plan()` refuses a target with no `runtimes-recipe/targets/<name>.toml` before any stage runs (riscv32 / armv6 musl today, P609). The cmake / ninja requirement is gone.
- The `--sysroot` of every compile is `<stage>/work/sysroot`: the libc-headers product's include dirs that SYSROOT.toml names (outermost first, no `c++/` dir at any depth; wasi's `eh/` `noeh/` too) plus the target's rendered SYSROOT.toml. The table's `clang_triple` must equal the target's after the quirks (else refusal: the tables carry the quirk flags of the triple they were derived for); the quirks' `cflags_add` are not applied again.
- builtins stage: the `builtins` runtime only, archived to `<out>/<builtins_name>` from the table's `<resource_layout>/<builtins_name>` archive. runtimes stage: `crt`, `libunwind`, `libcxxabi`, `libcxx` in one window, after `build/<key>.toml` is laid into `<stage>/work/build` ({build}); every [layout] gather item is looked up in the table at its root path (the map assemble applies forward), the `headers/<key>.toml` tree installed for the `include/c++/v1` item, crt objects to `<out>/crt/`. A table archive that no gather item takes is a failure, not a silent drop. The products keep the B1 stage contract; assemble is unchanged.
- Compiles: `ctx->kcc(<sysroot>)` + `[flags].<lang>` + group flags (`{src}`, `{build}`, `{sysroot}`, `{share}` filled) + `-ffile-prefix-map=<src>=kairo-runtimes -ffile-prefix-map=<work>=kairo-work`, through `SysJobs`; `ksys -j N` / `--jobs N` (else `KSYS_JOBS`, else the hardware thread count) bounds it. A failed compile is P010E with its first error line, the log in the note.
- Archives: in-process (`LinkFS::write_archive_as`), members in table order, symbol table, deterministic; COFF format for COFF triples, as llvm-ar picks it from COFF members. `write_archive` now names members by basename, as llvm-ar does: it used the whole path, so every musl libc.a (and libkairo.a for MinGW) carried the stage dir in its member names (P608).
- Parity (build/sysgen/b3/{parity,hello}.py): all 18 roots from a fresh cache, from a toolchain prefix with no sysroot/; every archive, crt object and c++/v1 tree byte-identical to the Python runner's, and the comparison with the curated roots identical to B2's table (glibc/BSD/wasi equal to curated; musl/mingw the known Alpine / llvm-mingw provenance differences). Hello in C, C++ (iostream, thread, filesystem, a thread_local with a destructor, an exception) and Kairo: run natively on x86_64/i686 musl + glibc, under qemu for aarch64/armv7/riscv64 musl, node for wasm; link-only for mingw, BSD and the non-x86 glibc roots (no target glibc for qemu -L). 268 s for all 18 (5-23 s each; the runtimes stages are ~5 s of it).
- Not done: the builtins required-symbols check (section 4.5) and `post_archive` (msvc only); the glibc runtimes are compiled against the requested version's headers, not the floor's (moot while 2.31 is the only version); a toolchain whose `<prefix>/sysroot/<target>` exists still compiles the runtimes against that root (kcc prefers it over `--sysroot`, P610).


## 19. State after wave Z2 (2026-11-09): generic targets and the runtimes template

**Target model** (Linker/Sysroot/Names.k). Any well-formed triple names a target, not just the section 14 table. The table is matched first (exact name, triple via `same_target`, prefix completion: every existing spelling and every refusal are unchanged); a triple the table lacks gets its family from llvm::Triple's OS and environment (linux + musl* / gnu* / none, windows + gnu / msvc, freebsd*, netbsd*, wasi*, darwin), its arch spelled as the triple spells it, and its name and clang triple from `SysNames::make` (32-bit Arm on Linux is always eabihf; a soft-float `musleabi` / `gnueabi` is refused, since names carry no float ABI; an unknown Linux environment is refused; any other OS keeps "not a sysroot name"). glibc versions: `-glibc<X.Y>` (canonical, in the name) or Zig's `<...>-gnu<env>.<X.Y>` (x86_64-linux-gnu.2.17 = x86_64-linux-gnu-glibc2.17). Whether a target can be built is asked afterwards, each with its own P009E: the backend (TargetRegistry in-process, as before: no backend list anywhere), the provider (`<family> has no port for <arch>`: the recipe's `arches`), the runtimes template's domain. A recipe `clang_triple` template left with an unexpanded `{per_arch.*}` (an arch it has no row for) no longer replaces the built-in triple.

`SysNames::properties(t)` (twin of `props_of()` in Scripts/runtimes_template.py): libc, os, objfmt, bits, int128, cpu, rt_arch (compiler-rt's builtins arch), float, crt_arch, endian, arch, plus descriptive threads (posix / win32 / none) and exceptions (dwarf / seh / arm-ehabi / none). The arch rules cover the backends added after 0.2.1 too (P663: powerpc, systemz, mips, loongarch, sparc for cpu / bits / endian; compiler-rt's spellings for rt_arch, sparc64 = sparcv9), though no provider has inputs for them yet. `ksys probe` prints them as one `properties:` row after `tools:`, with `backend=<TargetRegistry name>`.

**Runtimes template** (FORMAT.md "runtimes-template/", Linker/Sysroot/Template.k `SysTemplate`). `Scripts/runtimes_template.py` derives it from runtimes-recipe/ tables: per sequence (a runtime's flags for one language, a group-flag profile, an archive's member list) the per-target sequences are merged by progressive LCS into one supersequence; a run of nodes present on the same targets is a fragment; its `when` is the conjunction over properties (DNF if none fits) with the fewest excluded values that holds on exactly those targets (the others that compile that sequence are negatives; for archives and objects every target is). It writes the template and re-instantiates every input target from the written files, failing on any difference. When registry.toml lists `runtimes-template`, plan() takes it as an input (runtimes-recipe then only if also listed), refuses an out-of-domain target before any stage, and the builtins/runtimes stages instantiate it into `<stage>/work/tables` in the runtimes-recipe layout (`SysRuntimes::from_template`), so the B3 compile / archive / header code runs unchanged; build/ and headers/ come from the template's per-family copies. Without it, the tables as before (they stay as the fallback until Z3 registers the template). `ksys tables <target> --out DIR` writes the tables a target compiles from, unbuilt.

Fixups (applied to the input tables before derivation, printed by the script): armv6 hard-float builtins get `-DCOMPILER_RT_ARMHF_TARGET` (P640; CMake's list omits armv6, so every float/double-returning builtin used the soft-float pcs: this was P609's armv6 tfbf.k exit 0); riscv32 musl builtins get compiler-rt's atomic.c (P641; libc++ needs `__atomic_*_8`, musl has no libatomic).

**Proof.** (a) The script: 20/20 targets (18 shipped + B3's CMake tables for armv6/riscv32 musl) instantiate to their tables. (b) ksys: `ksys tables` for all 20 equals the CMake tables (for armv6/riscv32: with the two fixups applied) semantically (member -> source + full flag list, archive paths and member order, objects; build/sysgen/z2/cmp_tables.py). (c) Bytes: all 18 roots from a template-only share and from a tables-only share, same toolchain prefix without sysroot/: every archive, crt object, c++/v1 tree and the rest of the root byte-identical (LICENSES/<input> named after the input), `kcc -###` against each root shows `-isysroot <root>` and no bundled sysroot (build/sysgen/z2/parity.py; transitively equal to Scripts/build_runtimes_direct.py, which B3 showed the tables path matches). Run on the binary one reformat before the final one; (b) was re-run on the final binary. (d) armv6-linux-musl and riscv32-linux-musl build from the template and validate under qemu (t.c 7, t.cpp 12, test.k 0, floats.k 5, tfbf.k 1).

**Generality, measured** (with the fixups). Leaving each of the 20 targets out of the derivation in turn: crt 12/12, libunwind 16/20, libc++abi 16/19, libc++ 16/20 and builtins 5/20 come back identical. Builtins needs compiler-rt's per-arch source lists, which only a table for that arch carries. So the template serves the targets it was derived from plus new combinations of their property values, best effort; a new rt_arch / libc / cpu (thumbv7em, a `none` OS) is refused, not guessed. aarch64_be and thumbv7 musl parse and have the backends, but are refused at the provider: the musl recipe has no `arches` / `[per_arch.musl_arch]` / `linux-uapi/asm/<arch>` for them, and the armv7-musl-hardfloat quirk matches armv7/armv6 only, so thumbv7 would also lose its `hf`. Not done: a no-threads variant (libc++'s `__config_site` comes from the family's headers tree, one per family) and bare metal (section 4 stretch).


## 20. State after wave Z3 (2026-11-09): schema 2 share, libc from source, the template registered

**Schema 2 reader** (P612; FORMAT.md "schema 2"). `ShareTree` reads `schema = 1` and `2` and refuses any other. Under schema 2 `SysUtil::tree_sha256` / `tree_stamp` never follow a link and a link below an input root is a refusal naming it (`verify-share` prints `ERROR <key>`); the input root itself may be a link (share views). Every provider copies an input subdir through `StageCtx::materialise` (`SysRun::materialise`): the files, then each `links.tsv` row under it as the same symlink (on Windows, or where a link fails, a copy of what the row resolves to inside the input: the twin of `resolve_recorded`), then each `casefold.tsv` row renamed back, or its `.kcase` dropped when the destination folds case (probed in the destination). `--share` / `KAIRO_SYSROOT_SHARE` are made absolute (P670: a relative path missed `-ffile-prefix-map` and put the share's path into the runtimes objects). build/sysroot-share is schema 2 (`ship_sysroot_inputs.py --upgrade-schema`); a ksys from before Z3 refuses it (P674).

**mingw: lib/ from mingw-crt** (FORMAT.md "mingw-crt"; port of Scripts/build_mingw_crt_direct.py). `Linker/Sysroot/CrtTable.k` reads mingw-crt/<arch>.toml and wasi-libc/<name>.toml in one pass (`SysCrtTable`) and runs their compiles (`SysCrt::compile`: every `[def.*]` through `kcc -E -P -x c ... -o`, then `strip_at`, and every `[group.*]` entry, one `SysJobs` window). `MingwProvider` builds from it whenever mingw-crt is a verified input (the recipe lists `inputs = ["mingw", "mingw-crt"]`): `{sysroot}` = `SysRuntimes::header_root` (mingw/include + the rendered SYSROOT.toml, now `SysRecipe::render_toml`), `[files]`, compiles, archives in table order (import libraries through the in-process dlltool, then `llvm-ar qc` for members in parallel, then `llvm-ar qcL` for the MRI `addlib` merges, an empty archive where nothing was written), `mingw/crt/<arch>` (the 9 files mingw-w64-crt does not build, P623) and then `[install]` into lib/. Without mingw-crt, the old defs + crt path. mingw/def/ is gone from the share (P622).

**wasi: the libc from wasi-libc** (FORMAT.md "wasi-libc"). New provider `wasi` (`SysNames::provider_of`; Providers/Wasi.k): libc-headers = the wasi/<v> base per `[bundle_layout]` (libc++ `eh/` `noeh/`, `lib/wasm32-wasi/llvm-lto`) + the table's `[headers]`; libc-libs (after builtins) = `{sysroot}` from `[headers]`, SYSROOT.toml and the builtins archive, the compiles, GNU archives in-process, `empty` archives, then every `[link.*]` with `kld -flavor wasm` (never a kcc link, P591), `[install]` into `{sysroot}` after the archives and after each link; lib/ is the product. wasi/33 no longer ships the 232 files this builds (P624).

**Runtimes template registered.** `ship_sysroot_inputs.py` step `runtimes-template` (`--template-recipes build/sysgen/b3/rr-with-armv6-riscv32`): registry key, `licenses/runtimes-template/`, provenance; runtimes-recipe stays registered. plan() takes the template, so armv6 and riscv32 musl build from the real share.

**P642**: musl `arches` + aarch64_be, thumbv7; `[per_arch.musl_arch]` rows; `[per_arch.uapi_arch]` + `uapi = [..., "linux-uapi/asm/{per_arch.uapi_arch}"]`; quirk key `match_cpu` (Names.k `cpu_of`; Scripts/runtimes_recipe.py reads it too), and armv7-musl-hardfloat matches `match_cpu = ["arm"]`; the qemu runner maps every cpu=arm arch to qemu-arm. Both build and validate under qemu; thumbv7 is A32 code as clang's driver makes it (P672).

**Proof** (build/sysgen/z3: setup.py, parity.py, hello.py; logs there). Final debug binary, toolchain prefix without sysroot/, scratch caches.
- Schema: the sealed share with its `links.tsv` / `casefold.tsv` undone in a hard-link copy hashes (schema 1 rule) to every pre-Z3 registry value; Python-zipfile and tar extracts of the whole share both verify all 17 keys, 0 links; FreeBSD x86_64 built from the zip extract = built from the tree; built from schema 1 = from schema 2 (links included).
- From source vs the reference runners: wasm32-wasi lib/ + headers 232/232 and x86_64-windows-gnu [install] 938/938 byte-identical.
- 20 targets (18 bundled + armv6/riscv32 musl) from the upgraded share, 353.7 s in all (glibc 11-13 s, BSD 11-12 s, wasi 16 s, musl 20-21 s, mingw 20-31 s). The 15 non-mingw/wasi roots are byte-identical (every file and link but .kairo-sysroot.json) to the pre-Z3 ksys's (build/sysgen/z2/tc) from the same inputs as a schema 1 view. Against the curated roots: wasi 19/19 differing libs same defined-symbol set and member lists, headers identical; mingw (x86_64 / i686 / aarch64 / armv7) 80/91/66/71 lib/ files differ in bytes, all but libc++.a (the known runtimes provenance delta) with the curated defined-symbol set, and every differing archive with the curated member list; the rest as before Z3.
- Hellos (C; C++ iostream/thread/filesystem/thread_local dtor/exception; Kairo), `-###` shows the root, no bundled one: native x86_64/i686 musl + glibc, qemu aarch64/armv7/armv6/riscv64/riscv32 musl, node wasm, Proton wine x86_64/i686 MinGW; link-only aarch64/armv7 MinGW, BSD, non-x86 glibc.
- `package_release.py --stage-only x86_64-linux-musl` (relcand tree, hard-linked): the staged share verifies (17 inputs; ksys verify-share: 17 ok, 0 links).

Not done: copy fallback and case-insensitive casefold never ran on a filesystem that needs them; wasi libc++ and llvm-lto from source (P624, P626); noeh/ still shipped (P671); Tests/CLI/Sysroot/build_runtimes.k NORECIPE (P673).


## 21. State after wave Z5 (2026-11-09): musl on the new LLVM arches, runtimes for the new glibc arches

**Inputs.** `linux-uapi/asm/{powerpc,s390,mips,loongarch,sparc}/` (kernel ARCH names) from `make O=<scratch> headers_install` of the Linux 7.0 tree at build/sysgen/linux (`ship_sysroot_inputs.py --linux-src`): the output minus `generic/` by name, every shared file byte-identical to `generic/` but the five the curated (Alpine) set carries in its own form (FORMAT.md "Input dir layouts"); the same rule on ARCH=x86 / arm64 gives the shipped asm/x86_64 / asm/aarch64 exactly, so generic/ stays one set. x32 uses asm/x86_64 (unistd_x32.h is there). The musl recipe gains powerpc powerpc64 powerpc64le s390x mips mipsel mips64 mips64el loongarch64 x32; its triple, clang_triple and resource_layout are `[per_arch.triple]` / `[per_arch.clang_triple]` rows now (x32, Names.k arch "x32", is spelled through its environment: x86_64-linux-muslx32), rendering byte-identical for every earlier arch; `[per_arch.musl_arch]` (x32 -> x32, powerpc64le -> powerpc64, mipsel -> mips, mips64el -> mips64) and `[per_arch.uapi_arch]`. No cc_define or per-arch flag: clang's defaults are the ABIs musl's configure accepts (ppc64 ELFv2, ppc long double = double, mips o32 / n64 hard-float, loongarch64 lp64d, x32 ILP32) and kcc passes configure's asm probes (PowerPC 'd' constraint, LoongArch FCSR), so Providers/Musl.k is unchanged.

**Quirks** (quirks.toml): atomics-in-builtins-32 (musl + glibc powerpc / mips / mipsel: no 8-byte lock-free atomics and no libatomic, so compiler-rt's atomic.c; the Kairo runtime's mimalloc needs __atomic_load_8), x32-libunwind-narrowing (LLVM 22 libunwind narrows a u64 link_reg_t into x32's u32 pint_t in an init-list; `-Wno-c++11-narrowing`, kept through the derivation's warning filter), sparc64-as-sparcv9 (glibc: target_rewrite, since compiler-rt names the arch sparcv9 and with DEFAULT_TARGET_ONLY reads it off the triple).

**Runtimes.** CMake tables for 21 targets (the 10 musl + the 11 new glibc arches at 2.42, `runtimes_recipe.py --headers` fed from ksys libc-headers products; build/sysgen/z5/rrshare/runtimes-recipe). `runtimes_recipe.py`: EXTRA lists them; an EXTRA glibc arch is named for the newest version (bundled stay 2.31); the BFLOAT16 `assert_cache_regex` is skipped where kcc rejects `__bf16` (PowerPC, SystemZ, MIPS, SPARC have none); a dynamic (debug) kit links lib/*.so*. `runtimes_template.py`: x32 properties (bits=32, int128 native, rt_arch / crt_arch x32, twin of Names.k); two family build/headers keys with the same content are one family tree. Registered template (`--template-recipes build/sysgen/b3/rr-with-armv6-riscv32 build/sysgen/z5/rrshare/runtimes-recipe`): 41 targets, all re-instantiated IDENTICAL; `ksys tables` byte-identical to the pre-Z5 template's output for the 22 earlier targets (20 + aarch64_be, thumbv7 musl), and equal to the CMake tables for the 21 new ones (build/sysgen/z5/cmp_tables.py).

**Library and validate.** Lib/builtin/fmt/fmt_buf.k (P700, user-approved): each float put exists only where clang has the type (`eval if` at class-member scope: f16 `__FLT16_MAX__`, f128 `__SIZEOF_FLOAT128__` or wasm, bf16 by arch, f80 restored for x86 but MSVC / Android), and the sign-bit readers follow the target's byte order (negative floats printed unsigned on every big-endian target). expect.toml `[types]` names the float types a validate program spells; validate SKIPs it where a probe compile says the target lacks one. The qemu runner spells PowerPC qemu-ppc*; x32 runs natively (CONFIG_X86_X32_ABI). Toolchain.k: muslx32 links as elf32_x86_64 (was elf_x86_64).

**Gate** (build/sysgen/z5; toolchain prefix without sysroot/; real share through a runtimes view). ksys ensure, validate included: powerpc, powerpc64, powerpc64le, s390x, mips, mipsel, mips64, mips64el, loongarch64 musl pass under qemu (t.c 7, t.cpp 12, test.k 0; floats.k 5 on s390x / loongarch64, SKIP elsewhere; tfbf.k SKIP on all nine). Hellos (C; C++ iostream / thread / filesystem / thread_local dtor / exception; Kairo printing -1.5 and -0) run on all nine (hello5.py, hello2.log; -### shows -isysroot <root> and its c++/v1, no bundled root). x32 musl: root builds, C/C++ run natively, the Kairo library does not link (P702). glibc 2.42: loongarch64 and s390x pass (link-only); ppc* stop at Lib/rt/fmt_float.c (IBM long double, P703); mips* and sparc64 at kcc's dynamic-linker table (P704); gnux32 has no crt table (P704). The 20 earlier targets: tables parity only (unchanged), not rebuilt.


## 22. State after P743-P746 (2026-11-09): host roots on first use, one canonical --target

**The implicit target too.** Steps 2-3 of section 8 now run for the implicit (host default) target as well as an explicit `--target`; an explicit `--sysroot` still skips them. The bundle covers the host only on Linux and Windows archives: a hand-unzipped macOS, FreeBSD or NetBSD archive ships no root for its own host (`package_release.py` HOST_ROOTS), so a plain `kairo h.k` there had no system headers (P743). The cache lookup also runs before the "Apple / MSVC target on a host without its SDK" P008E, so a root staged by hand (`ksys ensure --input`) serves any host.

**SDK families** (`Linker/Sysroot/Sdk.k`, `SysSdk`; `SysGen.ensure` dispatches darwin and windows-msvc to it before `plan()`, and the driver does not require a share tree for them). A Kairo port of the fast path of `scripts/darwin-sysroot.sh` / `scripts/msvc-sysroot` (stage the SDK, lay `share/kairo/sdk-overlays/<darwin|msvc>-<arch>` over it, write SYSROOT.toml, check, validate), into the sysroot cache like a generated root. The overlay dir is `<prefix>/share/kairo/sdk-overlays`, else `sdk-overlays` beside the share tree (a development tree's `build/sdk-overlays`).

- darwin: the SDK is `--input`, else (macOS hosts only) `Toolchain::find_sdk("macos")` (SDKROOT, DEVELOPER_DIR, the xcode-select link, the Command Line Tools, Xcode.app), else `xcrun --sdk macosx --show-sdk-path` when developer tools are selected (the bare xcrun shim would pop the installer). Staged as stage_sdk does (Apple's `c++/` headers, `libc++*.tbd`, `swift/` and swift module files left out; files hard-linked where possible). SYSROOT.toml is emit_toml's, with no `clang_triple`: the driver puts a root's `clang_triple` in place of the user's `--target`, which would turn a spelled `arm64-apple-macosx13.0` into the floor.
- msvc: the splat is `--input`, else `$XWIN`, else `$MSVC_CACHE` or `<prefix>/share/kairo/msvc-cache` `/splat` (the script's cache). With none, on a Windows host with Visual Studio's C++ tools (vswhere), ksys runs `scripts/msvc-sysroot.ps1 <arch>` with OUT in the cache (the VS + Windows Kits layout is read by the script's PowerShell half, not ported). With neither: P009E naming the exact `powershell -ExecutionPolicy Bypass -File <prefix>/scripts/msvc-sysroot.ps1 <arch>` command; the splat is a licensed download and is never fetched silently.
- No overlay (arm64e, an archive without overlays): refusal naming the script's `--from-source` build (cmake + ninja).
- Key: name, the SDK's real path and SDKSettings.json hash (a splat: path and `sdk/include/um` stamp), the overlay's REVISION and stamp, the toolchain version. A later `ensure` with nothing to stage from reuses the by-name root.
- Validate: the structural checks of the scripts, then `kcc -c` of their C++ program against the root (compile only: the link would build the Kairo library inside the first use); skipped when a bundled `<prefix>/sysroot/<name>` would shadow `--sysroot`.

**Canonical --target** (`CompilerSetup._canonical_target`, first thing in `_apply_invocation`): a glibc version (`-glibc2.28`, Zig's `.2.28`) is split off by `SysNames::split_glibc` (the parser `parse` uses) into `TargetOptions::glibc`, so clang, the env macro and the link see the plain triple (P745); `_sysroot_target` puts it back as the root's name and the bundled lookup then matches that name exactly (a plain `x86_64-linux-gnu` still finds the bundled 2.31 by spelling). A macOS triple with no OS version gets the deployment floor (`Toolchain::with_os_floor`: 11.0 arm64/arm64e, 10.15 x86_64), since clang's default has no TLS (P746). FreeBSD / NetBSD / Linux / Windows / wasm triples are left as spelled.

**Generic darwin** (`SysNames::_generic`): only macOS (darwin / macosx OS) is the darwin family; iOS and the other Darwin OSes no longer parse to the macOS root.

**armv7 hosts** (P750): the native default treats a plain gnu / musl environment on 32-bit Arm as hard-float, as `canonical_triple` does for `--target`; the armv7 archives' LLVM_HOST_TRIPLE (`armv7-linux-musl`) made the default soft-float, and Lib/builtin's bf16 failed CL001E on every native build.

Not done: the darwin and msvc paths are unit-tested off-host only (`ksys ensure --input`, Tests/CLI/Sysroot/sdk_stage.k); the xcrun, vswhere and PowerShell branches need a real Mac / Windows. `ksys probe` / `build` for darwin and msvc still go through `plan()` and the user provider's refusal.

