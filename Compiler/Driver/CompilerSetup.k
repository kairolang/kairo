/// --- The Kairo Project ----------------------- Driver/CompilerSetup.k --- ///
///
///   CompilerInstance, part: setup. Target and sysroot selection (the
///   effective triple, the bundled sysroot, the header roots), the clang
///   backend's configuration, and what _apply_invocation maps from the
///   invocation onto the live subsystems (host system, package words,
///   search roots, code policy). Fields and construction stay in
///   CompilerInstance.k; this is an `extend` reaching them as `prot`
///   (Driver/module.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/TargetParser/Host.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "llvm/MC/TargetRegistry.h"
ffi "c++" import "llvm/ADT/APFloat.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticIDs.h"
ffi "c++" import "clang/Basic/DiagnosticOptions.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Basic/TargetOptions.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"
ffi "c++" import "string"

import API::EnvNames::EnvNames
import API::FS::LinkFS
import API::HostSystem::{
    HostSystem,
    PkgConfigError,
}
import API::SysrootManifest::SysrootManifest
import API::Text::LinkText
import API::Toolchain::Toolchain
import AST::LangItems::LowerTargets
import Command::FlagTranslator::{
    ClangSpelling,
    FlagTranslator,
}
import Config::Diagnostic::{
    ErrorFormat,
    renders_through_basic,
}
import Config::ResourceLayout::ResourceLayout
import Config::Target::{
    ObjectFormat,
    object_format_name,
}
import Diagnostic::BasicConsumer::BasicDiagConsumer
import Diagnostic::Engine::{
    DiagAction,
    diag_policy_key_from_string,
}
import Diagnostic::PrettyConsumer::PrettyDiagConsumer
import Diagnostic::Registry::DiagID
import Driver::CompilerInstance::CompilerInstance
import Driver::CompilerNative
import Interop::Clang::ClangBackend::ClangBackendConfig
import Support::FileIO::Path::Path
import Sysroot::Cache::SysCache
import Sysroot::Generator::SysGen
import Sysroot::Names::{
    SysNames,
    SysTarget,
    glibc_default_version,
}
import Sysroot::Outcome::{
    SYS_STATUS_FAILED,
    SYS_STATUS_REFUSED,
    SysOutcome,
}
import Sysroot::Sdk::SysSdk
import Sysroot::Share::ShareTree
import std::env
import std::io

extend CompilerInstance {
    /// # Identity actions

    fn get_target_triple(self) -> string {
        var triple = llvm::Triple(
            llvm::Triple::normalize(
                llvm::StringRef(llvm::sys::getProcessTriple()),
            ),
        )

        if triple.getVendor() == llvm::Triple::UnknownVendor && triple.isOSLinux() {
            triple.setVendor(llvm::Triple::PC)
        }

        return kairo::std::from_std_string<string>(triple.getTriple())
    }

    /// The triple compiled for without --target: the host's arch and OS with
    /// a C library the compiler ships. Windows is <arch>-pc-windows-gnu,
    /// never msvc. Linux follows the C library the HOST runs (its dynamic
    /// loader, HostSystem::host_libc): <arch>-unknown-linux-gnu on a glibc
    /// host, built against the bundled glibc 2.31 sysroot (the floor, so the
    /// program runs on any glibc since), and <arch>-unknown-linux-musl
    /// otherwise; the eabi/eabihf float ABI is kept on 32-bit ARM. Any other
    /// host keeps its own triple. --native uses the same triple.
    fn get_default_target_triple(self) -> string {
        var triple = llvm::Triple(
            llvm::Triple::normalize(kairo::sref(self.get_target_triple())),
        )

        if triple.isOSWindows() {
            triple.setVendor(llvm::Triple::PC)
            triple.setEnvironment(llvm::Triple::GNU)
        } else if triple.isOSLinux() {
            // Vendor `unknown`, not the host's: the bundled musl sysroots are
            // built for <arch>-unknown-linux-musl (clang's canonical spelling,
            // and the name of their compiler-rt directory). A host-derived
            // x86_64-pc-linux-musl names no directory any of them ships, so
            // every clang that is handed kairo's target -- the tests' link
            // driver, a user's build system -- misses libclang_rt.builtins.
            // The same rule holds for the glibc default: x86_64-unknown-linux-gnu.
            triple.setVendor(llvm::Triple::UnknownVendor)
            var env = triple.getEnvironment()
            // A plain gnu / musl on 32-bit Arm is the hard-float ABI here, as
            // Toolchain::canonical_triple reads an explicit --target: the
            // armv7 hosts' LLVM_HOST_TRIPLE is armv7-linux-musl, and taken as
            // soft-float the native default compiled against the hard-float
            // root and looked for the soft-float loader.
            var plain_arm = (triple.isARM() || triple.isThumb())
                && (env == llvm::Triple::GNU || env == llvm::Triple::Musl)
            var hf = env == llvm::Triple::GNUEABIHF || env == llvm::Triple::MuslEABIHF || plain_arm
            var eabi                 = env == llvm::Triple::GNUEABI || env == llvm::Triple::MuslEABI
            var an:  llvm::StringRef = triple.getArchName()
            var glibc = HostSystem::host_libc(
                Toolchain::canon_arch(
                    string(
                        unsafe ((an.data() as unsafe *const u8) as *const u8),
                        an.size(),
                    ),
                ),
                hf,
            ) == "glibc"
            if hf {
                triple.setEnvironment(
                    if (glibc) => (llvm::Triple::GNUEABIHF) else => llvm::Triple::MuslEABIHF,
                )
            } else if eabi {
                triple.setEnvironment(
                    if (glibc) => (llvm::Triple::GNUEABI) else => llvm::Triple::MuslEABI,
                )
            } else {
                triple.setEnvironment(
                    if (glibc) => (llvm::Triple::GNU) else => llvm::Triple::Musl,
                )
            }
        }

        return kairo::std::from_std_string<string>(triple.getTriple())
    }

    /// Header roots for --sysroot, resolved the way the linker resolves the
    /// same flag (Toolchain::resolve), so the two halves cannot disagree.
    ///
    ///   SYSROOT.toml  its include_dirs under <dir>/<sysroot>; that root is
    ///                 also -isysroot.
    ///   Apple SDK     <sdk>/usr/include{/c++/v1}: --sysroot is the SDK root,
    ///                 as for ld's -syslibroot and SDKSettings.json.
    ///   otherwise     nothing here; ClangBackend keeps the prefix model.
    ///
    /// Apple roots of either kind also get System/Library/Frameworks. A
    /// manifest that fails to load is left to the linker to report.
    priv fn _sysroot_header_roots(self, @inout bcfg: ClangBackendConfig) {
        var sr = LinkText::strip_slash(bcfg.sysroot)
        if sr.empty() || sr == "/" {
            return
        }

        var tri = llvm::Triple(
            llvm::Triple::normalize(kairo::sref(bcfg.triple)),
        )

        var darwin = tri.isOSDarwin()

        var root  = sr
        var dirs  = cxx::std::vector<string>()
        var mpath = LinkText::join(sr, SysrootManifest::file_name())
        if LinkFS::is_file(mpath) {
            var m = SysrootManifest()
            if !SysrootManifest::load(mpath, &m) {
                return
            }

            if !m.sysroot.empty() && m.sysroot != "." {
                root = LinkText::join(sr, m.sysroot)
            }

            for *d in m.include_dirs {
                dirs.push_back(LinkText::join(root, (*d)))
            }

            for *d in m.cc_defines {
                bcfg.defines.push_back(*d)
            }

            bcfg.clang_triple = m.clang_triple
        } else if darwin {
            dirs.push_back(LinkText::join(sr, "usr/include/c++/v1"))
            dirs.push_back(LinkText::join(sr, "usr/include"))
        } else {
            return
        }

        bcfg.sysroot = root
        for *d in dirs {
            if LinkText::contains(*d, "/c++/") {
                bcfg.cxx_include_dirs.push_back(*d)
            } else {
                bcfg.include_dirs.push_back(*d)
            }
        }

        if darwin {
            var fw = LinkText::join(root, "System/Library/Frameworks")
            if LinkFS::is_dir(fw) {
                bcfg.framework_dirs.push_back(fw)
            }
        }
    }

    /// A --target picks the sysroot bundled beside this binary,
    /// <prefix>/sysroot/<target> with <prefix> the directory above bin/, over
    /// --sysroot. One --sysroot then serves every host build while each
    /// --target gets headers and libraries for its own ABI; a single
    /// sysroot shared across targets makes clang reject the C library's
    /// typedefs (size_t is `unsigned long` in x86_64 musl and `unsigned int`
    /// on i386) and makes uint64_t 32 bits on Windows.
    ///
    /// A directory named exactly as --target is spelled wins. Otherwise any
    /// directory whose name is the same target in another spelling matches
    /// (Toolchain::same_target, plus the sub-arch so arm64e is not arm64):
    /// x86_64-pc-windows-msvc finds x86_64-windows-msvc, and llvm reads
    /// x86_64-linux-gnu-glibc2.31 as a gnu environment, so x86_64-linux-gnu
    /// finds that. Of several such, the first by name, so the pick never
    /// follows readdir order. -m32/-m64 look up the arch they switch to, as
    /// the rest of the driver does: --target=x86_64-linux-musl -m32 finds
    /// i686-linux-musl.
    ///
    /// Without --target the same lookup runs for the default target
    /// (get_default_target_triple), unless --sysroot was given: an explicit
    /// --sysroot outranks only an implicit target.
    ///
    /// No match is not an error: --sysroot is used if given, and otherwise
    /// there are no system headers. A match that is not a directory holding
    /// a loadable SYSROOT.toml is P007E: compiling against half a sysroot
    /// fails much later, far from the cause.
    ///
    /// \return false if a match was malformed (already reported).
    priv fn _use_bundled_sysroot(self) -> bool {
        var *tg = &self.invocation()->target
        // --native: the host is the sysroot. The bundle for the host's C
        // library is still found, by _apply_host_system, for its libc++ and
        // compiler-rt only.
        if tg->native {
            if tg->sysroot.empty() {
                tg->sysroot = "/"
            }

            return true
        }

        // --sysroot-exact: the caller (ksys building a root) names the
        // exact headers to compile against. A bundled root for the same
        // triple (x86_64-linux-gnu-glibc2.31 while building 2.42) would
        // otherwise win and mix two C libraries' headers.
        if self.invocation()->args.get_bool("sysroot-exact") && !tg->sysroot.empty() {
            return true
        }

        var want = self._sysroot_target()
        if want.empty() {
            return true
        }

        var dir = self._bundled_sysroot_dir(want)
        if dir.empty() {
            return self._sysroot_from_generator(want)
        }

        var why   = ""
        var mpath = LinkText::join(dir, SysrootManifest::file_name())
        if !LinkFS::is_dir(dir) {
            why = "it is not a directory"
        } else if !LinkFS::is_file(mpath) {
            why = "it has no SYSROOT.toml"
        } else {
            var m = SysrootManifest()
            if !SysrootManifest::load(mpath, &m) {
                why = f"SYSROOT.toml: {m.error}"
            }
        }

        if !why.empty() {
            self._diag->report(
                DiagID::P007E,
                f"the bundled sysroot for '{want}' is malformed: {dir}",
            ).emit()
            self._diag->report(DiagID::P007N, why).emit()
            return false
        }

        tg->sysroot = dir
        return true
    }

    /// SysRoot.md section 8, steps 2 and 3, for a target with no bundled
    /// sysroot: the generator's cache (<cache>/by-name/<name>), then `ksys
    /// ensure`, in-process, as the linker library is called rather than kld.
    ///
    /// For an explicit --target and for the implicit one alike, with no
    /// --sysroot: an explicit --sysroot outranks anything built. The
    /// implicit target is not skipped as "the bundle covers the host": that
    /// holds for Linux and Windows archives only, and a hand-unzipped macOS
    /// or BSD archive ships no root for its own host, so a plain `kairo h.k`
    /// there would have no system headers at all.
    ///
    /// Not under --freestanding or --macos-sdk (no root wanted, or one
    /// given), and not for Apple / MSVC targets on hosts without their SDK:
    /// those stay _check_sysroot's P008E, which names the scripts that build
    /// them. On their own host they are staged from the installed SDK
    /// (Linker/Sysroot/Sdk.k), which needs no share tree. The build is
    /// skipped for --help, --version and the info queries, which must not
    /// spend minutes on a root they never read.
    ///
    /// No share tree (a development tree, or a toolchain that ships no
    /// inputs) keeps today's P008W for the generated families: there is
    /// nothing to build from, and the warning already says to pass
    /// --sysroot. --no-sysroot-build makes the missing root a refusal
    /// either way.
    ///
    /// \return false on a refusal or failure (reported; _sysroot_status set).
    priv fn _sysroot_from_generator(self, const want: string) -> bool {
        var *inv = self.invocation()
        var *tg  = &inv->target
        if !tg->sysroot.empty() {
            return true
        }

        if inv->lang.freestanding || inv->linker.freestanding || !inv->linker.macos_sdk.empty() {
            return true
        }

        var tgt   = SysTarget{}
        var cands = cxx::std::vector<string>()
        var why   = ""
        var name  = want
        var sdk   = false
        if SysNames::parse(want, glibc_default_version(), &tgt, &cands, &why) {
            name = tgt.name
            sdk  = SysSdk::handles(&tgt)
        }

        // Before the SDK check: a macOS / MSVC root staged by hand (ksys
        // ensure --input, the SDK= of the scripts) serves any host.
        var cache  = SysCache(SysCache::default_root())
        var cached = if (cache.root.empty()) => ("") else => cache.lookup(name)
        if !cached.empty()
            && LinkFS::is_file(
                LinkText::join(cached, SysrootManifest::file_name()),
            ) {
            tg->sysroot = cached
            return true
        }

        if self._unshipped_sdk(want) {
            return true
        }

        if inv->args.get_bool("no-sysroot-build") {
            self._diag->report(
                DiagID::P009E,
                f"no sysroot for target \x27{want}\x27: none is installed or cached, and --no-sysroot-build forbids building one",
            ).emit()
            self._diag->report(
                DiagID::P009N,
                "pass --sysroot=<dir>, or drop --no-sysroot-build to let ksys build it",
            ).emit()
            self._sysroot_status = SYS_STATUS_REFUSED
            return false
        }

        if !sdk && !ShareTree::present(ShareTree::locate("")) {
            return true
        }

        if self.wants_help()
            || self.wants_version()
            || self.wants_explain()
            || self.wants_info_query() {
            return true
        }

        if sdk {
            io::eprintln(
                f"staging sysroot for {name} from the installed SDK, first time only",
            )
        } else {
            io::eprintln(f"building sysroot for {name}, first time only")
        }

        var gen  = SysGen()
        var path = ""
        var o    = SysOutcome()
        if gen.ensure(want, &path, &o) {
            tg->sysroot = path
            return true
        }

        var id = if (o.status == SYS_STATUS_FAILED) => (DiagID::P010E) else => DiagID::P009E
        self._diag->report(id, o.message).emit()
        if !o.note.empty() {
            self._diag->report(DiagID::P009N, o.note).emit()
        }

        self._sysroot_status = o.status
        return false
    }

    /// An Apple or MSVC target on a host that does not have its SDK: never
    /// shipped, never generated without --input (SysRoot.md section 12).
    priv fn _unshipped_sdk(self, const want: string) -> bool {
        var want_tri = llvm::Triple(llvm::Triple::normalize(kairo::sref(want)))
        var host_tri = llvm::Triple(
            llvm::Triple::normalize(
                kairo::sref(self.get_default_target_triple()),
            ),
        )

        return want_tri.isOSDarwin() && !host_tri.isOSDarwin()
            || want_tri.isWindowsMSVCEnvironment() && !host_tri.isOSWindows()
    }

    /// --target in the one spelling everything downstream reads, decided
    /// once:
    ///
    ///   - a glibc version, ours (`-glibc2.28`) or Zig's (`.2.28`), is split
    ///     off into TargetOptions::glibc by the parser ksys names targets
    ///     with (SysNames::split_glibc). The version names a sysroot, not a
    ///     triple: left in, clang refused `aarch64-unknown-linux-gnu.2.28`
    ///     and the env macro became `__kairo_env_gnu.2.28__`.
    ///   - a macOS triple with no version gets the deployment floor its
    ///     roots are built for (Toolchain::with_os_floor); clang's own
    ///     default has no thread-local storage.
    ///
    /// The sysroot lookups put the version back (_sysroot_target), so a
    /// pinned glibc still finds or builds its own root.
    priv fn _canonical_target(self) {
        var *tg = &self.invocation()->target
        if tg->triple.empty() {
            return
        }

        var ver  = ""
        var bare = SysNames::split_glibc(tg->triple, &ver)
        if !ver.empty() {
            tg->glibc  = ver
            tg->triple = bare
        }

        tg->triple = Toolchain::with_os_floor(tg->triple)
    }

    /// The triple whose bundled sysroot this run looks up: --target, else
    /// the default target unless --sysroot was given (""), switched by
    /// -m32/-m64.
    prot fn _sysroot_target(self) -> string {
        var *tg = &self.invocation()->target
        if tg->native {
            return ""
        }

        var want = tg->triple
        if want.empty() {
            if !tg->sysroot.empty() {
                return ""
            }

            want = self.get_default_target_triple()
        }

        if tg->m32 || tg->m64 {
            var tt = llvm::Triple(llvm::Triple::normalize(kairo::sref(want)))
            tt = if (tg->m32) => (tt.get32BitArchVariant()) else => tt.get64BitArchVariant()
            want = kairo::std::from_std_string<string>(tt.getTriple())
        }

        // A pinned glibc names its root (aarch64-linux-gnu-glibc2.28), which
        // _bundled_sysroot_dir matches exactly: the plain triple would find
        // the bundled 2.31 root by spelling and silently build against it.
        if !tg->glibc.empty() {
            var spelled = want + "-glibc" + tg->glibc
            var tgt     = SysTarget{}
            var cands   = cxx::std::vector<string>()
            var why     = ""
            want = spelled
            if SysNames::parse(
                spelled,
                glibc_default_version(),
                &tgt,
                &cands,
                &why,
            ) {
                want = tgt.name
            }
        }

        return want
    }

    /// <prefix>/sysroot/<want>, or the one directory there naming the same
    /// target in another spelling; "" for none.
    prot fn _bundled_sysroot_dir(self, const want: string) -> string {
        var prefix = Path::parent_of(Path::parent_of(env::exe_path()))
        var root   = LinkText::join(prefix, ResourceLayout::sysroot_subdir())
        var dir    = LinkText::join(root, want)
        if !LinkFS::exists(dir) && !self.invocation()->target.glibc.empty() {
            return ""
        }

        if !LinkFS::exists(dir) {
            var pick = ""
            for var name: string in LinkFS::list_dir(root) {
                // Only directories can be sysroots: the manifest file beside
                // them matched an unknown triple and was then reported as a
                // malformed sysroot instead of the real "unknown target".
                if !LinkFS::is_dir(LinkText::join(root, name)) {
                    continue
                }

                if !CompilerInstance::_same_bundled_target(name, want) {
                    continue
                }

                if pick.empty() || name < pick {
                    pick = name
                }
            }

            if pick.empty() {
                return ""
            }

            dir = LinkText::join(root, pick)
        }

        return dir
    }

    /// Whether the bundled sysroot directory \p name is for \p triple.
    priv static fn _same_bundled_target(const name: string, const triple: string) -> bool {
        if !Toolchain::same_target(name, triple) {
            return false
        }

        var ta = llvm::Triple(llvm::Triple::normalize(kairo::sref(name)))
        var tb = llvm::Triple(llvm::Triple::normalize(kairo::sref(triple)))
        return ta.getSubArch() == tb.getSubArch()
    }

    /// Returns the effective target triple: --target if given, else the
    /// default target (get_default_target_triple).
    ///
    /// Reads the typed option rather than the raw flag so it works on the
    /// invocation path too. TargetOptions::triple is set verbatim from
    /// `--target`, so the argv path is unaffected.
    prot fn _effective_triple(self) -> string {
        var *tg             = &self.invocation()->target
        var t               = tg->triple
        var explicit_target = !t.empty()
        if !explicit_target {
            t = self.get_default_target_triple()
        }

        // -m32/-m64 rewrite the ARCH of the triple, as clang does, so the cc1
        // `-triple` agrees with the sysroot _use_bundled_sysroot picked with
        // the same rewrite: left at x86_64, --m32 compiled 64-bit code against
        // the i686 headers and died on the size_t typedef mismatch. -m32 wins
        // when both are given (matches _use_bundled_sysroot). An arch with no
        // such variant has pointer width 0 after the rewrite and keeps its
        // own triple instead of becoming "unknown".
        if tg->m32 || tg->m64 {
            var tri0 = llvm::Triple(llvm::Triple::normalize(kairo::sref(t)))
            var wide = tri0
            wide = if (tg->m32) => (tri0.get32BitArchVariant()) else => tri0.get64BitArchVariant()
            if wide.getArchPointerBitWidth() != 0 {
                t = kairo::std::from_std_string<string>(wide.getTriple())
            }
        }

        // Canonicalized here so clang, codegen and the linker all see the
        // same float ABI (see Toolchain::canonical_triple).
        if explicit_target {
            return Toolchain::canonical_triple(t)
        }

        return t
    }

    /// Looks up a registered target by triple. Returns nullptr if not found
    /// and writes the LLVM error message to `err_out`.
    priv fn _lookup_target(self, const triple: string, @inout err_out: string) -> unsafe *void {
        var result:    unsafe *void     = &null
        var err:       cxx::std::string
        var triple_str                  = triple

        var llvm_triple = llvm::Triple(
            llvm::Triple::normalize(kairo::sref(triple_str)),
        )

        var unsafe *T = llvm::TargetRegistry::lookupTarget(llvm_triple, &err)

        if T == &null {
            (err_out) = kairo::std::from_std_string<string>(err)
        }

        result = unsafe ((unsafe (T as unsafe *const void)) as unsafe *void)
        return result
    }

    /// \brief the cc1 tokens `-ffast-math` stands for, as clang 22's driver
    ///        spells them (checked with `clang -### -ffast-math`). Shared by
    ///        -ffast-math and --fp-model=fast, which differ only in
    ///        -complex-range.
    ///
    /// \details Spelled out rather than taken from the driver probe: the probe
    ///          runs once per triple for target defaults, and its keep-list
    ///          would also have to carry a default-on `-ffp-contract=on`
    ///          that Kairo's cc1 line must not have.
    /// \brief the shared clang backend's configuration, from the
    ///        invocation: target, header roots, optimization and debug
    ///        info, the user's -W policy. initialize builds the backend from
    ///        it; --print-clang-args prints what it makes.
    prot fn _backend_config(self) -> ClangBackendConfig {
        var bcfg = ClangBackendConfig{}
        bcfg.triple = self._effective_triple()
        bcfg.wargs = FlagTranslator::warnings(
            &self.invocation()->diag,
            ClangSpelling::CC1,
        )

        // The target flags clang has a spelling for. Parsed into the
        // invocation long before this; until they are copied here they reach
        // nothing.
        var tgt = self.invocation()->target
        if !tgt.cxx_std.empty() {
            bcfg.cxx_std = tgt.cxx_std
        }

        // --march is a DRIVER spelling (cc1 has none): the probe turns it
        // into -target-cpu and the -target-feature pairs its extensions imply.
        for var a: string in FlagTranslator::march_driver(&tgt) {
            bcfg.driver_words.push_back(a)
        }

        // The AVR driver warns "no target microcontroller specified" for a
        // line without -mmcu, and picks no CPU: the probe is such a line
        // unless the --cxx-flags -mmcu reaches it too. Given it,
        // the probe's -target-cpu is the MCU the C inputs compile for.
        var mmcu_next = false
        for s in *self.invocation()->args.get_list("cxx-flags") {
            if mmcu_next || s.starts_with("-mmcu=") || s == "-mmcu" {
                bcfg.driver_words.push_back(s)
            }

            mmcu_next = s == "-mmcu"
        }

        // (bcfg.c_std stays c17: native_invocation builds only Lib/rt, Kairo's
        // own runtime; --c-std is for the user's C inputs.)
        // Every flag word below is spelled by FlagTranslator, the one home
        // of the kairo <-> clang mapping; this function only places them.
        for var a: string in FlagTranslator::target(&tgt, ClangSpelling::CC1) {
            bcfg.extra_cc1.push_back(a)
        }

        var missing_plugins = cxx::std::vector<string>()
        for var a: string in FlagTranslator::codegen(&*self.invocation(), bcfg.triple, ClangSpelling::CC1, unsafe &missing_plugins) {
            bcfg.extra_cc1.push_back(a)
        }

        for *pl in missing_plugins {
            self._diag->report(
                DiagID::U008E,
                f"--pass-plugin: no such plugin file '{(*pl)}'",
            ).emit()
        }

        // User header dirs and macros for C++ interop, ahead of the system
        // roots: -I / --ffi-include / --cxx-include (-I), --cxx-define (-D),
        // --cxx-undefine (-U).
        for var a: string in FlagTranslator::preprocessor(&*self.invocation()) {
            bcfg.extra_cc1.push_back(a)
        }

        // The triple's environment as a macro (`__kairo_env_musl__`):
        // clang predefines the arch and OS, but nothing tells musl from
        // glibc, which `__builtin_target_info()` (Lib/builtin) must.
        var env_tt = llvm::Triple(
            llvm::Triple::normalize(kairo::sref(bcfg.triple)),
        )

        var env_sr: llvm::StringRef = env_tt.getEnvironmentName()
        var env_nm = string(
            unsafe ((env_sr.data() as unsafe *const u8) as *const u8),
            env_sr.size(),
        )

        if env_nm.empty() {
            env_nm = "unknown"
        }

        bcfg.extra_cc1.push_back(
            f"-D{LowerTargets::reserved_prefix()}env_{env_nm}__=1",
        )

        // The runtime root, after the user's: `rt/fmt.h` names the same file
        // from Lib/builtin/fmt/fmt_buf.k (an ffi header set copies this
        // invocation) and from Lib/rt/fmt_*.c (native_invocation shares these
        // arguments).
        var rt_root = self._runtime_root()
        if !rt_root.empty() {
            bcfg.extra_cc1.push_back("-I")
            bcfg.extra_cc1.push_back(rt_root)
        }

        // The env search paths, where clang's driver puts them (Kairo's line
        // is built by hand, so nothing else would): CPATH as -I after every
        // command-line -I, C_INCLUDE_PATH / CPLUS_INCLUDE_PATH as the
        // per-language system groups, which clang searches after -isystem
        // and before -idirafter -- the sysroot's headers still win. Not in a
        // hermetic build, and not on a C/C++ input's driver line, where
        // clang's driver adds them itself (ClangJobs drops them when
        // hermetic).
        bcfg.strip_env = tgt.host_mode.empty()
        if !tgt.host_mode.empty() {
            for var d: string in HostSystem::env_list(EnvNames::cpath()) {
                bcfg.extra_cc1.push_back("-I")
                bcfg.extra_cc1.push_back(d)
            }

            for var d: string in HostSystem::env_list(EnvNames::c_include_path()) {
                bcfg.extra_cc1.push_back("-c-isystem")
                bcfg.extra_cc1.push_back(d)
            }

            for var d: string in HostSystem::env_list(EnvNames::cplus_include_path()) {
                bcfg.extra_cc1.push_back("-cxx-isystem")
                bcfg.extra_cc1.push_back(d)
            }
        }

        // The two header-search roots, exactly as given: no discovery. With
        // neither, clang searches no system headers at all (see the model in
        // ClangBackend::_startup_locked), which is the honest answer.
        bcfg.sysroot      = tgt.sysroot
        bcfg.resource_dir = tgt.resource_dir
        self._sysroot_header_roots(&bcfg)
        // The host's system headers. Default ("floor"): after every sysroot
        // root, as -idirafter, so <stdio.h> is always the floor's and only a
        // header it lacks (zlib.h, curl/curl.h) is the host's. --native:
        // clang's native order -- the bundled libc++, the builtins, then the
        // host's dirs as the C library's -- with no sysroot at all.
        if tgt.host_mode == "floor" {
            for *d in tgt.host_include_dirs {
                bcfg.after_dirs.push_back(*d)
            }
        } else if tgt.host_mode == "native" {
            bcfg.sysroot = ""
            bcfg.cxx_include_dirs.clear()
            bcfg.include_dirs.clear()
            bcfg.defines.clear()
            if !tgt.native_bundle.empty() {
                var nb = ClangBackendConfig{}
                nb.triple  = bcfg.triple
                nb.sysroot = tgt.native_bundle
                self._sysroot_header_roots(&nb)
                for *d in nb.cxx_include_dirs {
                    bcfg.cxx_include_dirs.push_back(*d)
                }

                for *d in nb.defines {
                    bcfg.defines.push_back(*d)
                }
            } else if LinkFS::is_dir("/usr/include/c++/v1") {
                bcfg.cxx_include_dirs.push_back("/usr/include/c++/v1")
            }

            for *d in tgt.host_include_dirs {
                bcfg.include_dirs.push_back(*d)
            }
        }

        // One optimization level for the whole build: ClangBackend applies
        // it to the invocation every compile copies.
        var cgo = self.invocation()->codegen
        bcfg.opt_level = cgo.opt_level
        if cgo.opt_size_z {
            bcfg.opt_size = 2
        } else if cgo.opt_size {
            bcfg.opt_size = 1
        }

        bcfg.vectorize = cgo.f_vectorize != 0
        // -g0 wins over -g wherever it sits. --dwarf-version always has a
        // value (default 5), so it cannot say whether DWARF was asked for;
        // on MSVC it is left out and the driver emits CodeView, which is
        // what link.exe-style PDBs need.
        bcfg.debug_info    = FlagTranslator::debug_on(&cgo)
        bcfg.debug_macros  = cgo.debug_macros
        bcfg.embed_source  = cgo.embed_source
        bcfg.dwarf_version = FlagTranslator::dwarf_for(&cgo, bcfg.triple)
        return bcfg
    }

    /// Installs \p action for a user-spelled diagnostic code. A code the
    /// engine cannot key (no category prefix, no digits) is reported rather
    /// than dropped, so a typo does not look like it worked.
    priv fn _set_code_policy(self, const code: string, action: DiagAction) {
        var key = diag_policy_key_from_string(code)
        if key == 0 {
            self._diag->report(
                DiagID::U015W,
                f"ignoring diagnostic code '{code}': expected a category and number such as R020E",
            ).emit()
            return
        }

        self._diag->set_policy(key, action)
    }

    /// Every input-side path option made absolute, once, before anything
    /// reads one. A relative spelling that survives into the pipeline gets
    /// resolved against whatever directory the reader happens to be in:
    /// headers under a relative --sysroot are re-included from
    /// /kairo/pch/<id>.h and resolve against the PCH's directory, and
    /// --working-dir only chdirs AFTER this runs (apply_input_options), so
    /// -I and --sysroot must resolve before it, against the same directory.
    ///
    /// Relative paths are taken against --working-dir when given, else the
    /// cwd -- the directory the user meant, on the CLI and programmatic paths
    /// alike. Only paths that EXIST are rewritten (Path::absolute_if_exists):
    /// a missing one keeps the user's spelling for the diagnostic that
    /// rejects it. Output paths and --rpath are deliberately absent -- the
    /// first may not exist yet, the second names a directory on the TARGET.
    priv fn _absolutize_paths(self) {
        var *inv = self.invocation()
        var base = Path::absolute_if_exists(inv->working_dir)

        CompilerInstance::_absolutize_all(&inv->input_files, base)
        CompilerInstance::_absolutize_all(&inv->include_dirs, base)
        CompilerInstance::_absolutize_all(&inv->ffi_includes, base)
        CompilerInstance::_absolutize_all(&inv->cxx_includes, base)
        CompilerInstance::_absolutize_all(&inv->macro_paths, base)

        CompilerInstance::_absolutize_all(&inv->pp.force_includes, base)
        inv->pp.prelude_path = Path::absolute_if_exists(
            inv->pp.prelude_path,
            base,
        )

        inv->pp.builtins_dir = Path::absolute_if_exists(
            inv->pp.builtins_dir,
            base,
        )

        inv->pp.std_dir = Path::absolute_if_exists(inv->pp.std_dir, base)

        inv->target.sysroot = Path::absolute_if_exists(
            inv->target.sysroot,
            base,
        )

        inv->target.resource_dir = Path::absolute_if_exists(
            inv->target.resource_dir,
            base,
        )

        CompilerInstance::_absolutize_all(&inv->linker.lib_dirs, base)
        inv->linker.linker_script = Path::absolute_if_exists(
            inv->linker.linker_script,
            base,
        )

        inv->linker.version_script = Path::absolute_if_exists(
            inv->linker.version_script,
            base,
        )

        inv->linker.macos_sdk = Path::absolute_if_exists(
            inv->linker.macos_sdk,
            base,
        )

        inv->codegen.profile_use = Path::absolute_if_exists(
            inv->codegen.profile_use,
            base,
        )
    }

    /// The toolchain prefix: the directory above the one this binary is in
    /// (<prefix>/bin/kairo). get_exe_path is the resolved path, so a kairo
    /// on PATH that symlinks into a tree still finds that tree.
    priv static fn _toolchain_prefix() -> string {
        return Path::parent_of(Path::parent_of(env::exe_path()))
    }

    /// The highest-versioned directory under \p base holding the clang
    /// builtin headers (<ver>/include/stddef.h); "" for none. Highest, the
    /// rule lit.cfg.py and Scripts/stage_tree.py use, so a stale old version
    /// left beside the current one is never picked. Versions compare as
    /// numbers: longer first, then by spelling ("22" over "9").
    priv static fn _pick_resource_dir(const base: string) -> string {
        var pick = ""
        for var name: string in LinkFS::list_dir(base) {
            var cand = LinkText::join(base, name)
            if !LinkFS::is_file(LinkText::join(cand, "include/stddef.h")) {
                continue
            }

            var better = pick.empty()
            if !better {
                var cur = LinkFS::filename(pick)
                better = name.size() > cur.size() || name.size() == cur.size() && name > cur
            }

            if better {
                pick = cand
            }
        }

        return pick
    }

    /// Fills --resource-dir, --builtins-dir and --std-dir that were not
    /// given from the toolchain layout beside this binary, so a staged tree
    /// (Scripts/stage_tree.py) runs with no flags:
    ///
    ///   --resource-dir   <prefix>/lib/clang/<ver>
    ///   --builtins-dir   <prefix>/lib/builtin
    ///   --std-dir        <prefix>/lib/std
    ///
    /// A flag always wins. A GIVEN --resource-dir keeps its old meaning as
    /// well: its builtin/ and std/ are used when they exist, before the
    /// layout, so an install that put them there still works.
    ///
    /// A root that is still missing is a P001W (queued; initialize()
    /// reports it): without the builtin tree every lang item is unbound and
    /// `string` does not resolve, which otherwise reads as a sema bug rather
    /// than a missing directory. No std warning under --no-stdlib, and no
    /// builtin one under --no-prelude; --freestanding implies both.
    priv fn _discover_roots(self) {
        var *inv   = self.invocation()
        var prefix = CompilerInstance::_toolchain_prefix()
        var lib    = LinkText::join(prefix, ResourceLayout::lib_subdir())

        var rd_given = !inv->target.resource_dir.empty()
        if !rd_given {
            var rd = CompilerInstance::_pick_resource_dir(
                LinkText::join(lib, ResourceLayout::clang_subdir()),
            )

            if !rd.empty() {
                inv->target.resource_dir = rd
            } else {
                self._queue_root_warning(
                    f"clang resource directory not found: searched {lib}/clang/<version>/include/stddef.h",
                    "pass --resource-dir=<dir> naming the directory whose include/ holds clang's builtin headers (stddef.h)",
                )
            }
        }

        // --no-prelude / --freestanding: "builtin is not linked", so none is
        // looked for either. A found one would also bring the hosted runtime
        // (lib/rt: stdlib.h) into a bare-metal build; --builtins-dir still
        // adds it on purpose.
        if inv->pp.builtins_dir.empty() && !inv->pp.no_prelude {
            var legacy = ""
            if rd_given {
                legacy = LinkText::join(
                    inv->target.resource_dir,
                    ResourceLayout::builtin_subdir(),
                )
            }

            var dir = LinkText::join(lib, ResourceLayout::builtin_subdir())
            if !legacy.empty() && LinkFS::is_dir(legacy) {
                inv->pp.builtins_dir = legacy
            } else if LinkFS::is_dir(dir) {
                inv->pp.builtins_dir = dir
            } else {
                self._queue_root_warning(
                    f"builtin module tree not found: searched {dir}",
                    "pass --builtins-dir=<dir> naming the directory that holds builtin's module.k; without it the prelude does not load and lang items such as `string` stay unbound",
                )
            }
        }

        if inv->pp.std_dir.empty() && !inv->pp.no_stdlib {
            var legacy = ""
            if rd_given {
                legacy = LinkText::join(
                    inv->target.resource_dir,
                    ResourceLayout::std_subdir(),
                )
            }

            var dir = LinkText::join(lib, ResourceLayout::std_subdir())
            if !legacy.empty() && LinkFS::is_dir(legacy) {
                inv->pp.std_dir = legacy
            } else if LinkFS::is_dir(dir) {
                inv->pp.std_dir = dir
            } else {
                self._queue_root_warning(
                    f"standard library not found: searched {dir}",
                    "pass --std-dir=<dir> naming the standard library tree, or --no-stdlib to build without it",
                )
            }
        }
    }

    /// No usable sysroot is a P001W unless --freestanding asked for none:
    /// without one there are no C headers and no C library, and the failure
    /// otherwise surfaces far later as a missing <stddef.h> or an unresolved
    /// libc symbol. Runs after _use_bundled_sysroot, which has already put a
    /// bundled <prefix>/sysroot/<target> into --sysroot when there is one.
    /// --macos-sdk stands in for a sysroot on Darwin.
    ///
    /// A family that can never be shipped (Apple, MSVC) with no sysroot is a
    /// P008E and the compile stops: the cascade of missing-header errors
    /// from lib/builtin it would otherwise run into names none of the
    /// cause. A host of that family is exempt, it has the installed SDK.
    ///
    /// \return false after reporting that error.
    priv fn _check_sysroot(self) -> bool {
        var *inv = self.invocation()
        if inv->lang.freestanding || inv->linker.freestanding {
            return true
        }

        if !inv->linker.macos_sdk.empty() {
            return true
        }

        var sr = inv->target.sysroot
        var note = "pass --sysroot=<dir>, or --freestanding to compile without system headers and libraries"
        if sr.empty() {
            var want = self._sysroot_target()
            if want.empty() {
                want = self._effective_triple()
            }

            var root = LinkText::join(
                CompilerInstance::_toolchain_prefix(),
                ResourceLayout::sysroot_subdir(),
            )

            if self._unshipped_sdk(want) {
                var want_tri = llvm::Triple(
                    llvm::Triple::normalize(kairo::sref(want)),
                )

                var script = if (want_tri.isOSDarwin()) => ("darwin-sysroot.sh")
                             else => "msvc-sysroot.sh"
                var scripts = LinkText::join(
                    CompilerInstance::_toolchain_prefix(),
                    ResourceLayout::scripts_subdir(),
                )

                self._diag->report(
                    DiagID::P008E,
                    f"no sysroot for target '{want}': its SDK is never shipped with the compiler",
                ).emit()
                self._diag->report(
                    DiagID::P008N,
                    f"{note}; or build one from your own SDK with {scripts}/{script}",
                ).emit()
                return false
            }

            self._queue_root_warning(
                f"no sysroot found for target '{want}': searched {root}/{want}",
                note,
            )
        } else if !LinkFS::is_dir(sr) {
            self._queue_root_warning(
                f"sysroot not found: {sr} is not a directory",
                note,
            )
        }

        return true
    }

    /// --native's own rules, before any root is resolved: it cannot be
    /// combined with --target (one names this machine, the other a triple
    /// built hermetically), and it is only wired for Linux hosts.
    priv fn _check_host_flags(self) -> bool {
        var *tg = &self.invocation()->target
        if !tg->native {
            return true
        }

        if !tg->triple.empty() {
            self._diag->report(
                DiagID::U016E,
                f"--native and --target={tg->triple} cannot be combined",
            ).emit()
            self._diag->report(
                DiagID::U016N,
                "--native builds for this machine against its own C library, headers and libraries; --target builds hermetically for the named triple against its bundled sysroot. Drop one of them",
            ).emit()
            return false
        }

        var host = llvm::Triple(
            llvm::Triple::normalize(kairo::sref(self.get_target_triple())),
        )

        if !host.isOSLinux() {
            self._diag->report(
                DiagID::U017E,
                "--native is only implemented for Linux hosts so far",
            ).emit()
            self._diag->report(
                DiagID::U017N,
                "build without it (the default) to use the bundled sysroot, or name the system root with --sysroot (on macOS, --macos-sdk)",
            ).emit()
            return false
        }

        return true
    }

    /// \brief decides how much of the host system this build sees
    ///        (TargetOptions::host_mode), finds those dirs, and applies
    ///        --pkg-config. Once, here; the backend config and the link only
    ///        read the result.
    ///
    /// \details "floor" is the default on a Linux host compiling for its own
    ///          arch with no --target, --sysroot or --freestanding: the
    ///          bundled sysroot is the C library, and the host's system dirs
    ///          come after it. --native is "native". Anything else is
    ///          hermetic: no host dirs and no host env search paths, so a
    ///          cross build is the same on every machine.
    ///
    ///          The env search paths are read where clang's driver would add
    ///          them (CPATH and friends in _backend_config, LIBRARY_PATH
    ///          here), and NIX_CFLAGS_COMPILE / NIX_LDFLAGS as Zig reads them:
    ///          on Nix the system dirs are not where the defaults look.
    ///
    /// \return false after reporting (a failed --pkg-config).
    priv fn _apply_host_system(self, sysroot_given: bool) -> bool {
        var *inv = self.invocation()
        var *tg  = &inv->target
        var host = llvm::Triple(
            llvm::Triple::normalize(kairo::sref(self.get_target_triple())),
        )

        var eff = llvm::Triple(
            llvm::Triple::normalize(kairo::sref(self._effective_triple())),
        )

        var freestanding = inv->lang.freestanding || inv->linker.freestanding
        var mode         = ""
        if tg->native {
            mode = "native"
        } else if tg->triple.empty()
            && !sysroot_given
            && !freestanding
            && host.isOSLinux()
            && eff.isOSLinux()
            && host.getArch() == eff.getArch() {
            mode = "floor"
        }

        tg->host_mode = mode

        if !mode.empty() {
            var an: llvm::StringRef = eff.getArchName()
            var arch = Toolchain::canon_arch(
                string(
                    unsafe ((an.data() as unsafe *const u8) as *const u8),
                    an.size(),
                ),
            )

            var en: llvm::StringRef = eff.getEnvironmentName()
            var env = string(
                unsafe ((en.data() as unsafe *const u8) as *const u8),
                en.size(),
            )

            var is64 = eff.isArch64Bit()

            var inc  = cxx::std::vector<string>()
            var seen = cxx::std::vector<string>()
            var nixc = HostSystem::split_words(
                LinkFS::env(EnvNames::nix_cflags_compile()),
            )

            for var i: usize = 0; i + 1 < nixc.size(); ++i {
                if nixc[i] == "-isystem" || nixc[i] == "-idirafter" {
                    HostSystem::add_dir(&inc, &seen, nixc[i + 1])
                    i += 1
                }
            }

            for var d: string in HostSystem::include_dirs(arch, env) {
                HostSystem::add_dir(&inc, &seen, d)
            }

            tg->host_include_dirs = inc

            var libs  = cxx::std::vector<string>()
            var seenl = cxx::std::vector<string>()
            var nixl = HostSystem::split_words(
                LinkFS::env(EnvNames::nix_ldflags()),
            )

            for var i: usize = 0; i < nixl.size(); ++i {
                var w = nixl[i]
                if (w == "-L" || w == "-rpath") && i + 1 < nixl.size() {
                    if w == "-L" {
                        HostSystem::add_dir(&libs, &seenl, nixl[i + 1])
                    } else {
                        inv->linker.rpath.push_back(nixl[i + 1])
                    }

                    i += 1
                } else if LinkText::starts_with(w, "-L") {
                    HostSystem::add_dir(
                        &libs,
                        &seenl,
                        LinkText::slice(w, 2, w.size()),
                    )
                }
            }

            for var d: string in HostSystem::lib_dirs(arch, env, is64) {
                HostSystem::add_dir(&libs, &seenl, d)
            }

            tg->host_lib_dirs = libs
            tg->env_lib_dirs  = HostSystem::env_list(EnvNames::library_path())

            if mode == "native" {
                var t = kairo::std::from_std_string<string>(eff.getTriple())
                tg->native_bundle = self._bundled_sysroot_dir(t)
                if tg->native_bundle.empty() {
                    self._queue_root_warning(
                        f"--native: no bundled sysroot for '{t}' to take libc++ and compiler-rt from",
                        "the build uses whatever C++ runtime the host has (-lc++, libgcc)",
                    )
                }
            }
        }

        if tg->pkg_config.empty() {
            return true
        }

        if !tg->triple.empty()
            && LinkFS::env(EnvNames::pkg_config_sysroot_dir()).empty()
            && LinkFS::env(EnvNames::pkg_config_libdir()).empty() {
            self._diag->report(
                DiagID::U018E,
                f"--pkg-config cannot be used with --target={tg->triple} as is: this machine's .pc files describe this machine, not the target",
            ).emit()
            self._diag->report(
                DiagID::U018N,
                "point PKG_CONFIG_SYSROOT_DIR or PKG_CONFIG_LIBDIR at the target's pkg-config tree",
            ).emit()
            return false
        }

        var ok = true
        for *name in tg->pkg_config {
            var words = cxx::std::vector<string>()
            try {
                HostSystem::pkg_config(*name, &words)
            } catch e: PkgConfigError {
                self._diag->report(
                    DiagID::U019E,
                    f"--pkg-config {(*name)}: {e.message}",
                ).emit()
                ok = false
                continue
            }

            self._apply_pkg_words(*name, &words)
        }

        return ok
    }

    /// One package's pkg-config words, into the lists the flags of the same
    /// spelling fill: -I/-isystem/-idirafter as --ffi-include, -D/-U as
    /// --cxx-define/--cxx-undefine, -L/-l/-pthread and -Wl, to the link. A
    /// -I or -L naming a host system dir is dropped: those are already
    /// searched after the sysroot, and as a -I/-L they would come before it
    /// (-I/usr/include ahead of libc++ is how <cstring> breaks).
    priv fn _apply_pkg_words(self, const name: string, @inout words: cxx::std::vector<string>) {
        var *inv       = self.invocation()
        var *tg        = &inv->target
        var i:   usize = 0
        while i < words.size() {
            var w   = words[i]
            var nxt = ""
            if i + 1 < words.size() {
                nxt = words[i + 1]
            }

            var kind        = ""
            var val         = ""
            var step: usize = 1
            if w == "-I" || w == "-isystem" || w == "-idirafter" {
                kind = "I"
                val  = nxt
                step = 2
            } else if LinkText::starts_with(w, "-isystem") {
                kind = "I"
                val  = LinkText::slice(w, 8, w.size())
            } else if LinkText::starts_with(w, "-idirafter") {
                kind = "I"
                val  = LinkText::slice(w, 10, w.size())
            } else if w == "-D" {
                kind = "D"
                val  = nxt
                step = 2
            } else if w == "-U" {
                kind = "U"
                val  = nxt
                step = 2
            } else if w == "-L" {
                kind = "L"
                val  = nxt
                step = 2
            } else if w == "-l" {
                kind = "l"
                val  = nxt
                step = 2
            } else if w == "-pthread" {
                kind = "l"
                val  = "pthread"
            } else if LinkText::starts_with(w, "-Wl,") {
                kind = "Wl"
                val  = LinkText::slice(w, 4, w.size())
            } else if LinkText::starts_with(w, "-I") {
                kind = "I"
                val  = LinkText::slice(w, 2, w.size())
            } else if LinkText::starts_with(w, "-D") {
                kind = "D"
                val  = LinkText::slice(w, 2, w.size())
            } else if LinkText::starts_with(w, "-U") {
                kind = "U"
                val  = LinkText::slice(w, 2, w.size())
            } else if LinkText::starts_with(w, "-L") {
                kind = "L"
                val  = LinkText::slice(w, 2, w.size())
            } else if LinkText::starts_with(w, "-l") {
                kind = "l"
                val  = LinkText::slice(w, 2, w.size())
            } else if LinkText::starts_with(w, "/")
                && (LinkText::ends_with(w, ".a") || HostSystem::is_shared(w)) {
                kind = "l"
                val  = w
            }

            i += step

            if kind.empty() {
                self._diag->report(
                    DiagID::U020W,
                    f"--pkg-config {name}: ignoring '{w}', which kairo has no place for",
                ).emit()
                continue
            }

            if val.empty() {
                continue
            }

            if kind == "I" {
                var sys = false
                var rv  = LinkFS::real(val)
                for *d in tg->host_include_dirs {
                    if LinkFS::real(*d) == rv {
                        sys = true
                    }
                }

                if !sys {
                    inv->ffi_includes.push_back(val)
                }
            } else if kind == "L" {
                var sys = false
                var rv  = LinkFS::real(val)
                for *d in tg->host_lib_dirs {
                    if LinkFS::real(*d) == rv {
                        sys = true
                    }
                }

                if !sys {
                    inv->linker.lib_dirs.push_back(val)
                }
            } else if kind == "D" {
                inv->cxx_defines.push_back(val)
            } else if kind == "U" {
                inv->cxx_undefines.push_back(val)
            } else if kind == "l" {
                inv->linker.link_libs.push_back(val)
            } else {
                var b: usize = 0
                for var k: usize = 0; k <= val.size(); ++k {
                    if k == val.size() || val[k] == (',' as u8) {
                        var part = LinkText::slice(val, b, k)
                        if !part.empty() {
                            inv->linker.ld_flags.push_back(part)
                        }

                        b = k + 1
                    }
                }
            }
        }
    }

    priv fn _queue_root_warning(self, const msg: string, const note: string) {
        self._root_warnings.push_back(msg)
        self._root_warnings.push_back(note)
    }

    /// The warnings _discover_roots and _check_sysroot queued, reported once
    /// the run is really compiling: --help, --version, --explain and the
    /// info queries never reach initialize(), and do not need the roots.
    prot fn _report_root_warnings(self) {
        for var i: usize = 0; i + 1 < self._root_warnings.size(); i += 2 {
            self._diag->report(DiagID::P008W, self._root_warnings[i]).emit()
            self._diag->report(DiagID::P008N, self._root_warnings[i + 1]).emit()
        }

        self._root_warnings.clear()
    }

    priv static fn _absolutize_all(@inout list: cxx::std::vector<string>, const base: string) {
        for var i: usize = 0; i < list.size(); ++i {
            (list)[i] = Path::absolute_if_exists((list)[i], base)
        }
    }

    /// Maps invocation fields to live subsystem setters. Called once after
    /// the invocation is built. Fields whose subsystem does not yet exist are
    /// silently accepted stored in the invocation for future use.
    prot fn _apply_invocation(self) {
        var d  = self.invocation()->diag
        var fe = self.invocation()->frontend

        // Only the formats a consumer exists for. msvc has no
        // consumer, so it is refused rather than rendered as pretty.
        if !d.format_known {
            if d.format == "msvc" {
                self._diag->report(
                    DiagID::U021E,
                    "error format 'msvc' is not implemented",
                ).emit()
            } else {
                self._diag->report(
                    DiagID::U021E,
                    f"unknown error format '{d.format}' (expected pretty, basic or json)",
                ).emit()
            }

            self.invocation()->ok = false
            return
        }

        if renders_through_basic(d.error_format) {
            self._diag->remove_consumer(
                unsafe (self._pretty as unsafe *PrettyDiagConsumer),
            )

            self._diag->add_consumer(
                unsafe (self._basic as unsafe *BasicDiagConsumer),
            )

            self._basic->set_json(d.error_format == ErrorFormat::Json)
            // Flag-parse diagnostics (U005W, -D shape errors) are already in
            // the pretty buffer; carry them over or basic mode never shows them.
            self._pretty->drain_into(
                unsafe (self._basic as unsafe *BasicDiagConsumer),
            )
        }

        self._basic->set_absolute_paths(d.absolute_paths)
        self._pretty->configure(
            d.show_context,
            d.max_context_lines as u32,
            d.absolute_paths,
        )

        if d.no_color {
            self._pretty->set_color(false)
        }

        // 0 = unlimited for the error, warning and note caps (Engine honours it).
        self._diag->set_error_limit(d.max_errors as u32)
        self._diag->set_warning_limit(d.max_warnings as u32)
        self._diag->set_note_limit(d.max_notes as u32)
        self._diag->set_fixit_limit(d.max_suggestions as u32)
        self._diag->set_warnings_as_errors(d.warnings_as_errors)
        self._diag->set_suppress_all_warnings(d.suppress_warnings)

        // Per-code diagnostic policy. A code is addressed by category prefix +
        // number (severity-letter-agnostic): R020, R020E and r020w are one key,
        // but SC005 and S005 are not. Applied in this order so the stronger
        // intent wins on a repeated code: allow < warn < deny < forbid, i.e.
        // `-A X -W X` leaves X enabled.
        for c in d.allow_list {
            self._set_code_policy(c, DiagAction::Silence)
        }

        for c in d.warn_list {
            self._set_code_policy(c, DiagAction::Warn)
        }

        for c in d.deny_list {
            self._set_code_policy(c, DiagAction::Promote)
        }

        for c in d.forbid_list {
            self._set_code_policy(c, DiagAction::Forbid)
        }

        // --quiet: nothing but errors. Warnings, notes and remarks are dropped
        // at the engine; the logger stream follows so verbose chatter cannot
        // leak around it.
        if fe.quiet {
            self._diag->set_quiet(true)
            kairo::Logger::set_level(kairo::Logger::Level::Error)
        }

        // Logger was initialised at Trace in main(); quiet it down unless
        // the user asked for verbose output. The stream level controls what is
        // echoed to stderr live (default Error); --verbose turns the terminal
        // into a running trace instead of something you read out of kairo.log
        // after the fact.
        // Under --quiet the level is already pinned to Error above.
        if !fe.quiet {
            if !fe.verbose {
                kairo::Logger::set_level(kairo::Logger::Level::Warn)
            } else {
                kairo::Logger::set_stream_level(kairo::Logger::Level::Info)
            }
        }

        // First: every later reader of --target (the sysroot lookups, ksys,
        // the cc1 and driver triples, the env macro, the link) sees one
        // canonical spelling.
        self._canonical_target()

        // Before _use_bundled_sysroot fills it: whether the user named the
        // root, which keeps a default build off the host's dirs.
        var sysroot_given = !self.invocation()->target.sysroot.empty()
        if !self._check_host_flags() {
            self.invocation()->ok = false
            return
        }

        // After the consumers are set up, so a malformed sysroot reports in
        // the format asked for.
        if !self._use_bundled_sysroot() {
            self.invocation()->ok = false
            return
        }

        self._absolutize_paths()

        // After absolutizing: discovery fills only the roots still empty, and
        // what it fills is already absolute (it hangs off the exe's path).
        // Before real() below, so a discovered resource dir is made
        // symlink-free exactly like a given one.
        self._discover_roots()
        if !self._check_sysroot() {
            self.invocation()->ok = false
            return
        }

        // Both roots also symlink-free from here on, on top of absolute:
        // clang reports headers under the real path, and the header set keys
        // on clang's spelling. real() leaves a path that does not exist
        // unchanged; the resolvers report it.
        var *tg = &self.invocation()->target
        if !tg->sysroot.empty() {
            tg->sysroot = LinkFS::real(tg->sysroot)
        }

        if !tg->resource_dir.empty() {
            tg->resource_dir = LinkFS::real(tg->resource_dir)
        }

        // The module roots too. A builtin root reached through a symlink
        // (a debug tree's lib/builtin -> Lib/builtin, or any --builtins-dir
        // that is one) left the lang items unbound and ICEd in
        // NullTestLowering; resolved, a debug run with no flags sees exactly
        // the roots lit passes.
        var *ppo = &self.invocation()->pp
        if !ppo->builtins_dir.empty() {
            ppo->builtins_dir = LinkFS::real(ppo->builtins_dir)
        }

        if !ppo->std_dir.empty() {
            ppo->std_dir = LinkFS::real(ppo->std_dir)
        }

        // The host system: which mode, its dirs, --pkg-config. After the
        // roots are final, before anything (the backend config, the link,
        // --print-clang-args) reads them.
        if !self._apply_host_system(sysroot_given) {
            self.invocation()->ok = false
            return
        }

        // Pointer width for usize/isize, off the effective triple. -m32/-m64
        // are applied as arch-variant rewrites first, matching clang: they
        // change WHICH triple we compile for, and the width follows from that.
        // Written onto the invocation so sema reads a plain number and Config/
        // never has to see LLVM.
        var triple_str       = self._effective_triple()
        var width:     usize = 64

        var tt = llvm::Triple(llvm::Triple::normalize(kairo::sref(triple_str)))
        if self._inv.target.m32 {
            tt = tt.get32BitArchVariant()
        } else if self._inv.target.m64 {
            tt = tt.get64BitArchVariant()
        }

        var w = tt.getArchPointerBitWidth()
        if w != 0 {
            width = (w as usize)
        }

        self.invocation()->target.pointer_width = width

        // The rest of the derived target facts, off the SAME Triple, so
        // pointer width and ISA can never disagree about which target this
        // is. Sema reads these; Config/ still never sees LLVM.
        var full: string = kairo::std::from_std_string<string>(tt.getTriple())
        var arch: llvm::StringRef = tt.getArchName()
        var vend: llvm::StringRef = tt.getVendorName()
        var osn:  llvm::StringRef = tt.getOSName()
        var env:  llvm::StringRef = tt.getEnvironmentName()

        var objfmt = CompilerInstance::_object_format_of(&tt)

        var *t = &self.invocation()->target
        t->effective_triple = full
        t->arch_name = string(
            unsafe ((arch.data() as unsafe *const u8) as *const u8),
            arch.size(),
        )

        t->vendor_name = string(
            unsafe ((vend.data() as unsafe *const u8) as *const u8),
            vend.size(),
        )

        t->os_name = string(
            unsafe ((osn.data() as unsafe *const u8) as *const u8),
            osn.size(),
        )

        t->env_name = string(
            unsafe ((env.data() as unsafe *const u8) as *const u8),
            env.size(),
        )

        t->object_format_kind = objfmt
        t->object_format      = object_format_name(objfmt)
        t->is_little_endian   = tt.isLittleEndian()
        t->is_x86             = tt.isX86()
        t->has_os             = tt.getOS() != llvm::Triple::UnknownOS
        self._fill_clang_type_facts(&tt)
        t->resolved = true

        var err: cxx::std::string
        var unsafe *T = llvm::TargetRegistry::lookupTarget(tt, &err)
        if T == &null {
            self._diag->report(
                DiagID::P004F,
                f"unknown target triple '{t->effective_triple}': {kairo::std::from_std_string<string>(err)}",
            ).emit()
            self.invocation()->ok = false
            return
        }

        // `--mcpu native` is the host's CPU, as clang's -mcpu=native is. cc1's
        // -target-cpu (what --mcpu forwards to, FlagTranslator::target) has no
        // `native`: the clang DRIVER resolves it, so kairo must too, here,
        // before the validity check and before anything forwards the name.
        // Resolved only for a host build: with --target the host's CPU names
        // nothing about the target, and guessing would silently build for a
        // machine nobody asked for.
        if self._inv.target.mcpu == "native" {
            if !self._inv.target.triple.empty() {
                self._diag->report(
                    DiagID::P006E,
                    f"'--mcpu native' names the host CPU and cannot be used with --target '{self._inv.target.triple}'",
                ).emit()
                self._diag->report(
                    DiagID::P006N,
                    f"name the CPU explicitly; run with --print-cpus --target={t->effective_triple} to list valid values",
                ).emit()
                self.invocation()->ok = false
                return
            }

            var host = llvm::sys::getHostCPUName()
            self.invocation()->target.mcpu = string(
                unsafe ((host.data() as unsafe *const u8) as *const u8),
                host.size(),
            )
        }

        if !self._inv.target.mcpu.empty() {
            var unsafe *STI = T->createMCSubtargetInfo(
                tt,
                kairo::sref(r""),
                kairo::sref(r""),
            )

            finally {
                @cxx::delete STI
            }

            if !STI->isCPUStringValid(kairo::sref(self._inv.target.mcpu)) {
                self._diag->report(
                    DiagID::P006E,
                    f"unknown target CPU '{self._inv.target.mcpu}' for target '{t->effective_triple}'",
                ).emit()
                self._diag->report(DiagID::P006N, // Maybe add a new diagnostic catogery for this? like Driver?
                    f"run with --print-cpus --target={t->effective_triple} to list valid values").emit()
                self.invocation()->ok = false
                return
            }
        }

        // On x86 --march names a CPU (clang's -march=haswell), so it is
        // checked against the same list before the driver probe forwards it:
        // an unknown name would otherwise reach clang's raw "unknown target
        // CPU" and stop the backend start (I006F). `native` is the clang
        // driver's to resolve. Elsewhere --march is an ISA string
        // (armv8.2-a+crypto, rv64gc) that only clang's per-target parsers
        // read, so it is left to them.
        var march = self._inv.target.march
        if (!march.empty()) && march != "native" && t->is_x86 {
            var unsafe *XSTI = T->createMCSubtargetInfo(
                tt,
                kairo::sref(r""),
                kairo::sref(r""),
            )

            finally {
                @cxx::delete XSTI
            }

            if !XSTI->isCPUStringValid(kairo::sref(march)) {
                self._diag->report(
                    DiagID::P006E,
                    f"unknown target CPU '{march}' given to --march for target '{t->effective_triple}'",
                ).emit()
                self._diag->report(
                    DiagID::P006N,
                    f"on x86 --march names a CPU; run with --print-cpus --target={t->effective_triple} to list valid values",
                ).emit()
                self.invocation()->ok = false
                return
            }
        }
    }

    /// The one llvm::Triple -> ObjectFormat switch, for the target facts
    /// (_apply_invocation) and --print-target-info alike.
    prot static fn _object_format_of(@inout tt: llvm::Triple) -> ObjectFormat {
        var f = ObjectFormat::Unknown
        match tt.getObjectFormat() {
            case llvm::Triple::COFF {
                f = ObjectFormat::Coff
            } case llvm::Triple::ELF {
                f = ObjectFormat::Elf
            } case llvm::Triple::MachO {
                f = ObjectFormat::MachO
            } case llvm::Triple::Wasm {
                f = ObjectFormat::Wasm
            } case llvm::Triple::XCOFF {
                f = ObjectFormat::Xcoff
            } case llvm::Triple::GOFF {
                f = ObjectFormat::Goff
            } case llvm::Triple::DXContainer {
                f = ObjectFormat::DxContainer
            } case llvm::Triple::SPIRV {
                f = ObjectFormat::Spirv
            } default {
                f = ObjectFormat::Unknown
            }
        }

        return f
    }

    /// Fill TargetOptions' `long double` block and int64_t spelling from
    /// clang::TargetInfo for \p tt, the same post -m32/-m64 Triple the rest
    /// of the derived facts came from.
    ///
    /// Asked of clang, not a triple list: both are ABI decisions clang already
    /// makes per triple, and every hand-written approximation has been wrong
    /// somewhere -- "is x86" for x87 on MSVC (binary64) and Android
    /// (binary128), "64-bit and not Windows" for `long` int64_t on Darwin,
    /// which is LP64 and still spells it `long long`. The TargetInfo is
    /// throwaway -- only the answers are kept, so Config/ and Sema still
    /// never see clang.
    priv fn _fill_clang_type_facts(self, @inout tt: llvm::Triple) {
        var *t = &self.invocation()->target

        var dopts = clang::DiagnosticOptions()
        var diags = clang::DiagnosticsEngine(
            clang::DiagnosticIDs::create(),
            &dopts,
            kairo::std::create<clang::IgnoringDiagConsumer>(),
            true,
        )

        var topts = cxx::std::make_shared<clang::TargetOptions>()
        topts->Triple = tt.getTriple()
        var ti = llvm::IntrusiveRefCntPtr<clang::TargetInfo>(
            clang::TargetInfo::CreateTargetInfo(&diags, &*topts),
        )

        // No TargetInfo means clang does not know the triple, and the
        // lookupTarget check right after this reports P004F and fails the
        // invocation. Fall back to the ISA so f80 does not add a second,
        // misleading error on top of that one.
        if ti.get() == &null {
            t->long_double_is_x87 = t->is_x86
            t->int64_is_long      = t->pointer_width == 64 && !tt.isOSWindows()
            t->usize_is_fixed     = !tt.isOSDarwin()
            t->isize_is_fixed     = !tt.isOSDarwin()
            t->wchar_bits         = if (tt.isOSWindows()) => (16) else => 32
            return
        }

        // CanonicalTypes spells i64/u64 from this. Any other answer than
        // `long` is `long long`: no target clang knows makes int64_t an `int`.
        t->int64_is_long = ti->getInt64Type() == clang::TargetInfo::SignedLong

        // RedeclMerge folds usize/isize into the fixed-width pair for the C++
        // collision check only when size_t / ptrdiff_t ARE that pair. Compared
        // as clang's IntType against the type kairo SPELLS for u<pw>/i<pw>:
        // Int64Type for 64 (the same answer int64_is_long came from, so u64's
        // spelling and size_t's cannot drift apart), `int` and `short` below
        // that (BuiltinTable's fixed rows). NOT getIntTypeByWidth: that walks
        // char/short/int/long/long long and answers `long` for 64 on every
        // LP64 target, Darwin included, where Int64Type is `long long` --
        // which is exactly the case this exists to tell apart.
        var pw_bits = ti->getPointerWidth(clang::LangAS::Default)
        var want_u: clang::TargetInfo::IntType = clang::TargetInfo::NoInt
        var want_s: clang::TargetInfo::IntType = clang::TargetInfo::NoInt
        if pw_bits == 64 {
            want_u = ti->getUInt64Type()
            want_s = ti->getInt64Type()
        }

        if pw_bits == 32 {
            want_u = clang::TargetInfo::UnsignedInt
            want_s = clang::TargetInfo::SignedInt
        }

        if pw_bits == 16 {
            want_u = clang::TargetInfo::UnsignedShort
            want_s = clang::TargetInfo::SignedShort
        }

        t->usize_is_fixed = ti->getSizeType() == want_u
        t->isize_is_fixed = ti->getPtrDiffType(clang::LangAS::Default) == want_s

        var *fmt          = &ti->getLongDoubleFormat()
        var is_x87        = fmt == &llvm::APFloat::x87DoubleExtended()
        var name:  string = "an unrecognized format"
        if is_x87 {
            name = "x87 extended"
        }

        if fmt == &llvm::APFloat::IEEEdouble() {
            name = "binary64"
        }

        if fmt == &llvm::APFloat::IEEEquad() {
            name = "binary128"
        }

        if fmt == &llvm::APFloat::PPCDoubleDouble() {
            name = "IBM double-double"
        }

        t->long_double_is_x87   = is_x87
        t->long_double_fmt_name = name
        t->long_double_bits     = (ti->getLongDoubleWidth() as usize)
        t->long_double_align    = (ti->getLongDoubleAlign() as usize)
        t->has_float128         = ti->hasFloat128Type()
        t->wchar_bits           = (ti->getWCharWidth() as usize)
    }
}
