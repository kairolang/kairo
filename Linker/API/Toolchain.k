/// --- The Kairo Project -------------------- Linker/API/Toolchain.k ------ ///
///
///   \brief Where everything a link needs lives, for one target and one
///          sysroot: library directories, crt objects, the GCC install,
///          compiler-rt, libc++, the dynamic linker, the emulation, and for
///          Apple targets the SDK, platform and deployment target.
///
///   This is the part of clang's driver kairo used to borrow through
///   `clang++ -###`. It reads the filesystem and the environment, nothing
///   else. What it cannot find is reported as a LinkMessage, never guessed.
///
///   \par Three sysroot shapes (ELF)
///     manifest  <sysroot>/SYSROOT.toml exists (ksys). The manifest is the
///               authority: lib dirs, crt objects, libc and libc++ link args,
///               runtime choice, static-only. lld gets --sysroot.
///     root      <sysroot>/usr/lib exists: a real root ("/", a chroot).
///               Searched as <root>/usr, then <root>.
///     prefix    anything else, e.g. --sysroot=/usr: the directory IS the
///               prefix. lld does NOT get --sysroot here. glibc's libc.so is
///               a linker script naming /usr/lib/libc.so.6, and lld re-roots
///               absolute script paths under --sysroot: /usr/usr/lib/...
///
///   \par Apple targets
///     Mach-O targets resolve against an SDK (style "sdk"), or a manifest
///     sysroot that wraps one. With no --sysroot, or "/", the SDK comes from
///     SDKROOT when it names the target's platform, then DEVELOPER_DIR, the
///     xcode-select link (/var/db/xcode_select_link), the Command Line Tools
///     and Xcode's default location. xcrun is never run: it is a process
///     spawn per link, and everything it reads is reachable from here.
///
///     The runtime is fixed. libSystem carries libc, libm, the unwinder and
///     its own copy of the builtins, so compiler-rt is linked when present
///     and its absence is not an error.
///
///     Deployment target: <PLATFORM>_DEPLOYMENT_TARGET, then the triple's OS
///     version, then the SDK version. The environment beats the triple
///     because the driver's default triple carries the host OS version,
///     which would make the variable dead for every host build.
///
///   \par Windows (COFF)
///     MinGW-w64 (<arch>-windows-gnu) links through lld's mingw driver,
///     MSVC (<arch>-windows-msvc) through lld-link. Any other Windows
///     environment is rejected. With a manifest the manifest is the
///     authority. Without one:
///       MinGW  the sysroot is searched for a mingw-w64 tree
///              (<sr>/<arch>-w64-mingw32, <sr>/usr/<arch>-w64-mingw32,
///              <sr>); a directory counts only if it holds crt2.o or
///              libmingw32.a, so --sysroot=/ never pulls in host ELF
///              libraries. GCC is looked for beside the tree.
///       MSVC   with no --sysroot, LIB (as vcvars sets it) is the search
///              path. With one, an xwin splat (crt/lib/<a>, sdk/lib/um/<a>,
///              sdk/lib/ucrt/<a>) or a Visual Studio / msvc-wine tree
///              (VC/Tools/MSVC/<v>/lib/<a>, Windows Kits/10/Lib/<v>/{ucrt,um}/<a>),
///              newest version first. The SDK's mixed-case file names
///              (Kernel32.Lib) do not resolve on a case-sensitive file
///              system; xwin and msvc-wine lower-case them, a raw copy does
///              not. The runtime is vcruntime; --rtlib=compiler-rt adds
///              clang_rt.builtins on top.
///     compiler-rt is also searched in the sysroot's own library
///     directories, where llvm-mingw and ksys keep it.
///
///   \par WebAssembly
///     WASI preview 1 (wasm32-wasip1, wasm32-wasi) and bare
///     (wasm32-unknown-unknown). Preview 2 is a component built around a
///     core module by wasm-component-ld, and emscripten owns its own link;
///     both are rejected. A wasi-sdk sysroot keeps wasi-libc and libc++ in
///     <sr>/lib/<arch>-<os>[-<env>]; the builtins come from the resource
///     directory (lib/wasi or lib/<triple>) or the sysroot's library dirs.
///
///   \par Runtime choice (ELF)
///     --rtlib wins, then the manifest. With neither, a glibc target with a
///     GCC install found gets libgcc (what the host's own objects were built
///     against); everything else gets compiler-rt. --unwindlib follows the
///     same order and defaults to match rtlib.
///
///   \par libc++ outside the sysroot
///     A dev-tree or relocated toolchain keeps libc++ beside clang, not in
///     the sysroot: <resource-dir>/../.. . When it is not one of the system
///     library directories, it is searched first (as clang does) and, for
///     dynamic links, added as an rpath, because the loader will never
///     find it otherwise.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringRef.h";
ffi "c++" import "llvm/TargetParser/Triple.h";

import Config::Target::*;
import Config::Linker::*;
import Linker::API::Text::*;
import Linker::API::FS::*;
import Linker::API::LinkDiag::*;
import Linker::API::SysrootManifest::*;

class Toolchain {
    pub var ok:             bool = false;
    pub var format:         string;     ///< ELF | Mach-O | COFF | Wasm

    pub var triple:         string;     ///< effective, as the driver resolved it
    pub var arch:           string;     ///< canonical: x86_64 i386 aarch64 arm riscv64 ...
    pub var os:             string;     ///< as spelled: linux, freebsd14.1, macosx14.0, ...
    pub var env:            string;     ///< gnu, musl, gnueabihf, simulator, "" ...
    pub var libc:           string;     ///< glibc | musl | bsd | libsystem | mingw | msvc | wasi | ""
    pub var is64:           bool = true;

    pub var sysroot:        string;
    pub var style:          string;     ///< manifest | root | prefix | sdk | msvc
    pub var pass_sysroot:   bool = false;
    pub var has_manifest:   bool = false;
    pub var manifest:       SysrootManifest;
    pub var static_only:    bool = false;

    pub var lib_dirs:       vec::<string>;  ///< system library search order
    pub var crt_dir:        string;
    pub var gcc_dir:        string;
    pub var toolchain_lib:  string;         ///< libc++ outside the system dirs, or ""

    pub var rtlib:          string;         ///< compiler-rt | libgcc | vcruntime
    pub var unwindlib:      string;         ///< libunwind | libgcc | none | libsystem | seh
    pub var rt_dir:         string;
    pub var rt_suffix:      string;         ///< "" per-target layout, "-<arch>" old layout
    pub var builtins:       string;

    pub var emulation:      string;         ///< ELF, MinGW (i386pep ...), Wasm (wasm32 | wasm64)
    pub var dynamic_linker: string;         ///< ELF

    pub var platform:       string;         ///< Mach-O: -platform_version name
    pub var darwin_arch:    string;         ///< Mach-O: -arch spelling
    pub var min_version:    string;         ///< Mach-O: deployment target
    pub var sdk_version:    string;         ///< Mach-O: SDK the image was linked against

    priv var _real_dirs:    vec::<string>;  ///< lib_dirs, symlinks resolved, for dedup

    // --- Resolution -------------------------------------------------------

    fn resolve(self, t: *TargetOptions, o: *LinkerOptions, msgs: ref!(vec::<LinkMessage>)) -> bool {
        var errs0 = LinkDiag::error_count(msgs);
        self.ok = false;

        if !t->resolved {
            msgs.push_back(LinkDiag::make(LinkSeverity::Fatal,
                "link: the target was never resolved; the driver fills TargetOptions before linking"));
            return false;
        }

        var fmt = t->object_format;
        if (fmt == "wasm") || (fmt == "WASM") { fmt = "Wasm"; }
        if (fmt != "ELF") && (fmt != "Mach-O") && (fmt != "COFF") && (fmt != "Wasm") {
            msgs.push_back(LinkDiag::make(LinkSeverity::Fatal,
                f"linking {t->object_format} output for {t->describe()} is not implemented; only ELF, Mach-O, COFF and Wasm targets link"));
            return false;
        }
        self.format = fmt;
        var darwin  = fmt == "Mach-O";
        var coff    = fmt == "COFF";
        var wasm    = fmt == "Wasm";

        self.triple = t->effective_triple;
        self.arch   = Toolchain::canon_arch(t->arch_name);
        self.os     = t->os_name;
        self.env    = t->env_name;
        self.is64   = (t->pointer_width == 0) || (t->pointer_width == 64);
        self.libc   = Toolchain::libc_of(self.os, self.env);

        if darwin {
            self.libc        = "libsystem";
            self.platform    = Toolchain::darwin_platform(self.os, self.env);
            self.darwin_arch = Toolchain::darwin_arch_of(t->arch_name, self.arch);
            if self.platform.empty() {
                msgs.push_back(LinkDiag::make(LinkSeverity::Fatal,
                    f"{self.triple} is Mach-O but names no Apple platform this linker knows"));
                return false;
            }
        }
        if coff {
            if Toolchain::is_mingw(self.triple)     { self.libc = "mingw"; }
            else if Toolchain::is_msvc(self.triple) { self.libc = "msvc";  }
            else {
                msgs.push_back(LinkDiag::make(LinkSeverity::Fatal,
                    f"{self.triple}: Windows targets link as MinGW-w64 (<arch>-windows-gnu) or MSVC (<arch>-windows-msvc), and this environment is neither"));
                return false;
            }
        }
        if wasm {
            if self.os == "wasip2" {
                msgs.push_back(LinkDiag::make(LinkSeverity::Fatal,
                    f"{self.triple}: WASI preview 2 output is a component, which wasm-component-ld builds around a core module; link for wasm32-wasip1 and componentize the result"));
                return false;
            }
            if LinkText::starts_with(self.os, "emscripten") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Fatal,
                    "emscripten links through emcc, which owns its JS glue and system libraries; target wasm32-wasip1 or wasm32-unknown-unknown"));
                return false;
            }
            self.libc = ("wasi") if (LinkText::starts_with(self.os, "wasi")) else ("");
        }

        var sr = LinkText::strip_slash(t->sysroot);
        if darwin && (sr.empty() || (sr == "/")) {
            sr = Toolchain::find_sdk(self.platform);
            if sr.empty() {
                msgs.push_back(LinkDiag::make(LinkSeverity::Fatal,
                    f"no {self.platform} SDK found: install the Command Line Tools (xcode-select --install), set SDKROOT, or pass --sysroot"));
                return false;
            }
        }
        if sr.empty() { sr = "/"; }
        self.sysroot = sr;

        var mpath = LinkText::join(sr, "SYSROOT.toml");
        if LinkFS::is_file(mpath) {
            if !SysrootManifest::load(mpath, self.manifest) {
                msgs.push_back(LinkDiag::make(LinkSeverity::Fatal, f"{mpath}: {self.manifest.error}"));
                return false;
            }
            self.has_manifest = true;
            self._layout_manifest(msgs);
        } else if darwin {
            self._layout_sdk(msgs);
        } else if coff && (self.libc == "mingw") {
            self._layout_mingw(t->arch_name, msgs);
        } else if coff {
            self._layout_msvc(msgs);
        } else if wasm {
            self._layout_wasm(msgs);
        } else {
            self._layout_host(t->arch_name);
        }

        self._pick_runtimes(o, msgs);
        if darwin {
            self._find_darwin_rt(t, msgs);
        } else if self.libc == "msvc" {
            if self.rtlib == "compiler-rt" { self._find_msvc_rt(t, msgs); }
        } else if self.rtlib == "compiler-rt" {
            self._find_compiler_rt(t, msgs);
        }
        self._find_toolchain_lib(t);

        if darwin {
            self._darwin_versions(msgs);
        } else {
            self.emulation = o->emulation;
            if self.emulation.empty() {
                if coff {
                    self.emulation = (Toolchain::pe_emulation_for(self.arch)) if (self.libc == "mingw") else ("");
                } else if wasm {
                    self.emulation = self.arch;
                } else {
                    self.emulation = Toolchain::emulation_for(self.arch, self.os, self.env);
                }
            }
            if coff && (self.libc == "mingw") && self.emulation.empty() {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"no PE emulation for {self.arch}; pass --emulation"));
            }
            if (!coff) && (!wasm) {
                self.dynamic_linker = o->dynamic_linker;
                if self.dynamic_linker.empty() {
                    self.dynamic_linker = Toolchain::dynamic_linker_for(self.arch, self.os, self.env, self.libc);
                }
            }
        }

        self.ok = LinkDiag::error_count(msgs) == errs0;
        return self.ok;
    }

    priv fn _layout_manifest(self, msgs: ref!(vec::<LinkMessage>)) {
        var m    = &(self.manifest);
        var root = m->dir;
        if (!m->sysroot.empty()) && (m->sysroot != ".") { root = LinkText::join(m->dir, m->sysroot); }

        self.sysroot      = LinkText::strip_slash(root);
        self.style        = "manifest";
        self.pass_sysroot = true;
        self.static_only  = m->is_static;

        for d: string in m->lib_dirs { self._add_dir(LinkText::join(self.sysroot, d)); }
        if self.lib_dirs.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"{m->path}: none of its lib_dirs exists under {self.sysroot}"));
        }

        if !Toolchain::same_target(m->triple, self.triple) {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"the sysroot {self.sysroot} is for {m->triple}, but the target is {self.triple}"));
        }

        if !m->crt_startup.empty() {
            for d: string in self.lib_dirs {
                if LinkFS::is_file(LinkText::join(d, m->crt_startup[0])) { self.crt_dir = d; break; }
            }
        }
    }

    /// An Apple SDK. lld searches <sdk>/usr/lib itself through -syslibroot;
    /// the directory is recorded so static archive lookups and --print-dirs
    /// see it.
    priv fn _layout_sdk(self, msgs: ref!(vec::<LinkMessage>)) {
        self.style        = "sdk";
        self.pass_sysroot = false;
        if !LinkFS::is_dir(self.sysroot) {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, f"the SDK {self.sysroot} does not exist"));
            return;
        }
        self._add_dir(LinkText::join(self.sysroot, "usr/lib"));
        if self.lib_dirs.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"{self.sysroot} is not an SDK: it has no usr/lib"));
        }
    }

    priv fn _layout_host(self, spelled_arch: string) {
        var bases = vec::<string>();
        var usr   = LinkText::join(self.sysroot, "usr");
        if LinkFS::is_dir(LinkText::join(usr, "lib")) || LinkFS::is_dir(LinkText::join(usr, "lib64")) {
            self.style = "root";
            bases.push_back(usr);
            bases.push_back(self.sysroot);
            self.pass_sysroot = self.sysroot != "/";
        } else {
            self.style = "prefix";
            bases.push_back(self.sysroot);
            self.pass_sysroot = false;
        }

        var ma = Toolchain::multiarch(self.arch, self.os, self.env);
        for b: string in bases {
            var lib = LinkText::join(b, "lib");
            if !ma.empty() { self._add_dir(LinkText::join(lib, ma)); }
            if self.is64 {
                self._add_dir(LinkText::join(b, "lib64"));
                self._add_dir(lib);
            } else {
                // A 32-bit link on a 64-bit multilib host: lib/ is the wrong
                // class and lld would take the first libc it finds there.
                var l32 = LinkText::join(b, "lib32");
                if LinkFS::is_dir(l32) { self._add_dir(l32); } else { self._add_dir(lib); }
            }
        }

        for d: string in self.lib_dirs {
            if LinkFS::is_file(LinkText::join(d, "crt1.o")) || LinkFS::is_file(LinkText::join(d, "Scrt1.o")) {
                self.crt_dir = d;
                break;
            }
        }

        self._find_gcc(bases, spelled_arch);
    }

    /// A mingw-w64 install without a manifest: a distro's
    /// /usr/<arch>-w64-mingw32, or an llvm-mingw / MSYS2 root that keeps
    /// <arch>-w64-mingw32/ inside. A lib dir counts only if it holds the
    /// mingw runtime.
    priv fn _layout_mingw(self, spelled_arch: string, msgs: ref!(vec::<LinkMessage>)) {
        self.style        = "prefix";
        self.pass_sysroot = false;

        var tris  = Toolchain::mingw_triples(spelled_arch, self.arch);
        var usr   = LinkText::join(self.sysroot, "usr");
        var bases = vec::<string>();
        for tr: string in tris {
            bases.push_back(LinkText::join(self.sysroot, tr));
            bases.push_back(LinkText::join(usr, tr));
        }
        bases.push_back(self.sysroot);

        for b: string in bases {
            var lib = LinkText::join(b, "lib");
            if LinkFS::is_file(LinkText::join(lib, "crt2.o"))
            || LinkFS::is_file(LinkText::join(lib, "libmingw32.a")) {
                self._add_dir(lib);
            }
        }
        if self.lib_dirs.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"no mingw-w64 runtime (crt2.o, libmingw32.a) under {self.sysroot}; pass --sysroot naming a mingw-w64 install or a ksys sysroot"));
            return;
        }
        for d: string in self.lib_dirs {
            if LinkFS::is_file(LinkText::join(d, "crt2.o")) { self.crt_dir = d; break; }
        }

        // GCC sits beside the mingw tree, not in it:
        // /usr/lib/gcc/x86_64-w64-mingw32/<v> for --sysroot=/usr/x86_64-w64-mingw32.
        var groots = vec::<string>();
        groots.push_back(LinkText::join(LinkText::join(self.sysroot, "lib"), "gcc"));
        groots.push_back(LinkText::join(LinkText::join(usr, "lib"), "gcc"));
        var up = LinkFS::parent(self.sysroot);
        if !up.empty() { groots.push_back(LinkText::join(LinkText::join(up, "lib"), "gcc")); }

        var best   = "";
        var best_v = "";
        for g: string in groots {
            if LinkFS::is_dir(g) { self._scan_gcc(g, tris, "", best, best_v); }
        }
        self.gcc_dir = best;
    }

    /// MSVC without a manifest. LIB first when no --sysroot was given
    /// (vcvars sets it); otherwise an xwin splat or a VS / msvc-wine tree
    /// under the sysroot.
    priv fn _layout_msvc(self, msgs: ref!(vec::<LinkMessage>)) {
        self.style        = "msvc";
        self.pass_sysroot = false;

        if self.sysroot == "/" {
            for d: string in Toolchain::_split(LinkFS::env("LIB"), ';') {
                if !d.empty() { self._add_dir(LinkText::strip_slash(d)); }
            }
        }

        if self.lib_dirs.empty() {
            var sr = self.sysroot;
            var xw = Toolchain::xwin_arch_dir(self.arch);
            var vs = Toolchain::msvc_arch_dir(self.arch);

            self._add_dir(LinkText::join(sr, f"crt/lib/{xw}"));
            self._add_dir(LinkText::join(sr, f"sdk/lib/um/{xw}"));
            self._add_dir(LinkText::join(sr, f"sdk/lib/ucrt/{xw}"));

            var vcs = vec::<string>();
            vcs.push_back("VC/Tools/MSVC");
            vcs.push_back("vc/tools/msvc");
            for vc: string in vcs {
                var root = LinkText::join(sr, vc);
                var v    = Toolchain::newest_version(root);
                if !v.empty() { self._add_dir(LinkText::join(root, f"{v}/lib/{vs}")); }
            }

            var kits = vec::<string>();
            kits.push_back("Windows Kits/10/Lib");
            kits.push_back("kits/10/Lib");
            kits.push_back("kits/10/lib");
            for k: string in kits {
                var root = LinkText::join(sr, k);
                var v    = Toolchain::newest_version(root);
                if v.empty() { continue; }
                self._add_dir(LinkText::join(root, f"{v}/ucrt/{vs}"));
                self._add_dir(LinkText::join(root, f"{v}/um/{vs}"));
            }
        }

        var missing = "";
        if self.find_lib_file("libcmt.lib").empty() && self.find_lib_file("msvcrt.lib").empty() {
            missing += " the MSVC CRT (libcmt.lib),";
        }
        if self.find_lib_file("libucrt.lib").empty() && self.find_lib_file("ucrt.lib").empty() {
            missing += " the UCRT (libucrt.lib),";
        }
        if self.find_lib_file("kernel32.lib").empty() {
            missing += " the Windows SDK (kernel32.lib),";
        }
        if !missing.empty() {
            var _where = ("LIB and ") if (self.sysroot == "/") else ("");
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"MSVC libraries not found:{LinkText::slice(missing, 0, missing.size() - 1)}; searched {_where}{self.sysroot}. Pass --sysroot naming an xwin splat, a msvc-wine install, or a ksys sysroot"));
        }
    }

    /// wasi-sdk layout: <sr>/lib/<arch>-<os>[-<env>]. wasip1 and the older
    /// wasi spelling find each other. A bare target has nothing to search.
    priv fn _layout_wasm(self, msgs: ref!(vec::<LinkMessage>)) {
        self.style        = "prefix";
        self.pass_sysroot = false;
        if self.libc.empty() { return; }

        var env = ("") if (self.env.empty()) else (f"-{self.env}");
        var lib = LinkText::join(self.sysroot, "lib");
        self._add_dir(LinkText::join(lib, f"{self.arch}-{self.os}{env}"));
        if self.os == "wasip1" { self._add_dir(LinkText::join(lib, f"{self.arch}-wasi{env}")); }
        if self.os == "wasi"   { self._add_dir(LinkText::join(lib, f"{self.arch}-wasip1{env}")); }
        if LinkFS::is_file(LinkText::join(lib, "crt1.o")) || LinkFS::is_file(LinkText::join(lib, "crt1-command.o")) {
            self._add_dir(lib);
        }

        if self.lib_dirs.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"no wasi-libc under {lib}/{self.arch}-{self.os}{env}; pass --sysroot naming a wasi-sdk sysroot (share/wasi-sysroot) or a ksys sysroot"));
            return;
        }
        for d: string in self.lib_dirs {
            if LinkFS::is_file(LinkText::join(d, "crt1-command.o")) || LinkFS::is_file(LinkText::join(d, "crt1.o")) {
                self.crt_dir = d;
                break;
            }
        }
    }

    priv fn _pick_runtimes(self, o: *LinkerOptions, msgs: ref!(vec::<LinkMessage>)) {
        if self.format == "Mach-O" {
            if (!o->rtlib.empty()) && (o->rtlib != "compiler-rt") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"--rtlib={o->rtlib}: Apple targets only use compiler-rt"));
            }
            if (!o->unwindlib.empty()) && (o->unwindlib != "libunwind") && (o->unwindlib != "none") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"--unwindlib={o->unwindlib}: Apple targets unwind through libSystem"));
            }
            self.rtlib     = "compiler-rt";
            self.unwindlib = "libsystem";
            return;
        }

        if self.libc == "msvc" {
            var rt = o->rtlib;
            if rt.empty() && self.has_manifest { rt = self.manifest.rtlib; }
            if rt.empty() { rt = "vcruntime"; }
            if (rt != "vcruntime") && (rt != "compiler-rt") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"--rtlib={rt}: MSVC targets use vcruntime, optionally with compiler-rt on top"));
            }
            if (!o->unwindlib.empty()) && (o->unwindlib != "none") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"--unwindlib={o->unwindlib}: MSVC targets unwind through SEH and vcruntime"));
            }
            self.rtlib     = rt;
            self.unwindlib = "seh";
            return;
        }

        if self.format == "Wasm" {
            var rt = o->rtlib;
            if rt.empty() && self.has_manifest { rt = self.manifest.rtlib; }
            if rt.empty() { rt = "compiler-rt"; }
            if rt != "compiler-rt" {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"--rtlib={rt}: wasm targets only use compiler-rt"));
            }
            var uw = o->unwindlib;
            if uw.empty() && self.has_manifest { uw = self.manifest.unwindlib; }
            if uw.empty() { uw = "none"; }
            if (uw != "none") && (uw != "libunwind") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"--unwindlib={uw}: wasm targets take libunwind (for -fwasm-exceptions) or none"));
            }
            self.rtlib     = rt;
            self.unwindlib = uw;
            return;
        }

        var rt = o->rtlib;
        if rt.empty() && self.has_manifest { rt = self.manifest.rtlib; }
        if rt.empty() {
            rt = ("libgcc") if (((self.libc == "glibc") || (self.libc == "mingw")) && (!self.gcc_dir.empty())) else ("compiler-rt");
        }
        if (rt != "libgcc") && (rt != "compiler-rt") {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"unknown --rtlib value {rt}; expected compiler-rt or libgcc"));
        }
        if (rt == "libgcc") && self.gcc_dir.empty() && (!self.has_manifest) {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"--rtlib=libgcc, but no GCC installation was found under {self.sysroot}"));
        }
        self.rtlib = rt;

        var uw = o->unwindlib;
        if uw.empty() && self.has_manifest { uw = self.manifest.unwindlib; }
        if uw.empty() { uw = ("libgcc") if (rt == "libgcc") else ("libunwind"); }
        if (uw != "libunwind") && (uw != "libgcc") && (uw != "none") {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"unknown --unwindlib value {uw}; expected libunwind, libgcc or none"));
        }
        self.unwindlib = uw;
    }

    priv fn _rt_roots(self, t: *TargetOptions) -> vec::<string> {
        var roots = vec::<string>();
        if self.has_manifest && (!self.manifest.resource_dir.empty()) {
            roots.push_back(LinkText::join(self.sysroot, self.manifest.resource_dir));
        }
        if !t->resource_dir.empty() { roots.push_back(LinkText::strip_slash(t->resource_dir)); }
        return roots;
    }

    priv fn _find_compiler_rt(self, t: *TargetOptions, msgs: ref!(vec::<LinkMessage>)) {
        var roots  = self._rt_roots(t);
        var tris   = self._rt_triples(t);
        var osdir  = Toolchain::os_dir(self.os);
        var rtarch = self.arch;
        if (self.arch == "arm") && LinkText::contains(self.env, "hf") { rtarch = "armhf"; }

        var looked = "";
        for root: string in roots {
            var lib = LinkText::join(root, "lib");
            for tr: string in tris {
                var d = LinkText::join(lib, tr);
                if self._try_rt(d, "") { return; }
                looked += f"\n  {d}";
            }
            if !osdir.empty() {
                var d = LinkText::join(lib, osdir);
                if self._try_rt(d, f"-{rtarch}") { return; }
                looked += f"\n  {d}";
            }
            if self._try_rt(lib, "") { return; }
            looked += f"\n  {lib}";
        }
        // llvm-mingw and ksys keep the builtins beside the CRT, old -<arch> layout.
        if (self.format == "COFF") || (self.format == "Wasm") {
            for d: string in self.lib_dirs {
                if self._try_rt(d, f"-{rtarch}") { return; }
                if self._try_rt(d, "") { return; }
                looked += f"\n  {d}";
            }
        }
        if looked.empty() {
            looked = "\n  (nowhere: pass --resource-dir, or give the sysroot manifest a resource_dir)";
        }
        msgs.push_back(LinkDiag::make(LinkSeverity::Error,
            f"compiler-rt builtins for {self.triple} not found; looked in:{looked}"));
    }

    /// <resource>/lib/darwin/libclang_rt.<os>.a, the only layout Apple
    /// compiler-rt uses. Missing is not an error: libSystem carries the
    /// builtins.
    priv fn _find_darwin_rt(self, t: *TargetOptions, msgs: ref!(vec::<LinkMessage>)) {
        var name = f"libclang_rt.{Toolchain::darwin_rt_os(self.platform)}.a";
        for root: string in self._rt_roots(t) {
            var d = LinkText::join(LinkText::join(root, "lib"), "darwin");
            var a = LinkText::join(d, name);
            if LinkFS::is_file(a) {
                self.rt_dir   = d;
                self.builtins = a;
                return;
            }
        }
        msgs.push_back(LinkDiag::make(LinkSeverity::Verbose,
            f"{name} not found under the resource directory; the builtins come from libSystem"));
    }

    /// clang_rt.builtins for MSVC: <resource>/lib/<triple>/clang_rt.builtins.lib,
    /// then the old <resource>/lib/windows/clang_rt.builtins-<arch>.lib.
    priv fn _find_msvc_rt(self, t: *TargetOptions, msgs: ref!(vec::<LinkMessage>)) {
        var looked = "";
        for root: string in self._rt_roots(t) {
            var lib = LinkText::join(root, "lib");
            for tr: string in self._rt_triples(t) {
                var a = LinkText::join(LinkText::join(lib, tr), "clang_rt.builtins.lib");
                if LinkFS::is_file(a) { self.rt_dir = LinkFS::parent(a); self.builtins = a; return; }
                looked += f"\n  {a}";
            }
            var w = LinkText::join(LinkText::join(lib, "windows"), f"clang_rt.builtins-{self.arch}.lib");
            if LinkFS::is_file(w) { self.rt_dir = LinkFS::parent(w); self.rt_suffix = f"-{self.arch}"; self.builtins = w; return; }
            looked += f"\n  {w}";
        }
        for d: string in self.lib_dirs {
            var a = LinkText::join(d, f"clang_rt.builtins-{self.arch}.lib");
            if LinkFS::is_file(a) { self.rt_dir = d; self.rt_suffix = f"-{self.arch}"; self.builtins = a; return; }
            looked += f"\n  {a}";
        }
        if looked.empty() { looked = "\n  (nowhere: pass --resource-dir)"; }
        msgs.push_back(LinkDiag::make(LinkSeverity::Error,
            f"--rtlib=compiler-rt: clang_rt.builtins for {self.triple} not found; looked for:{looked}"));
    }

    priv fn _try_rt(self, dir: string, suffix: string) -> bool {
        var a = LinkText::join(dir, f"libclang_rt.builtins{suffix}.a");
        if !LinkFS::is_file(a) { return false; }
        self.rt_dir    = dir;
        self.rt_suffix = suffix;
        self.builtins  = a;
        return true;
    }

    priv fn _rt_triples(self, t: *TargetOptions) -> vec::<string> {
        var out = vec::<string>();
        var env = ("") if (t->env_name.empty()) else (f"-{t->env_name}");
        Toolchain::_push_unique(out, self.triple);
        if self.has_manifest {
            // Spelled and normalized: a manifest saying armv7-linux-musl
            // ships compiler-rt under armv7-unknown-linux-musl, and the
            // target (now musleabihf) names neither.
            Toolchain::_push_unique(out, self.manifest.triple);
            var nm = std::string_to_nstring(self.manifest.triple);
            var norm: libcxx::string = llvm::Triple::normalize(llvm::StringRef(nm.raw(), nm.size()));
            Toolchain::_push_unique(out, string(norm.c_str(), norm.size()));
        }
        Toolchain::_push_unique(out, f"{t->arch_name}-unknown-{t->os_name}{env}");
        Toolchain::_push_unique(out, f"{t->arch_name}-{t->os_name}{env}");
        Toolchain::_push_unique(out, f"{t->arch_name}-pc-{t->os_name}{env}");
        if self.format == "COFF" {
            Toolchain::_push_unique(out, f"{t->arch_name}-w64-windows-gnu");
            Toolchain::_push_unique(out, f"{t->arch_name}-w64-mingw32");
        }
        return out;
    }

    priv fn _find_toolchain_lib(self, t: *TargetOptions) {
        if self.has_manifest || t->resource_dir.empty() { return; }
        var base = LinkFS::parent(LinkFS::parent(LinkText::strip_slash(t->resource_dir)));
        if base.empty() { return; }

        var cands = vec::<string>();
        for tr: string in self._rt_triples(t) { cands.push_back(LinkText::join(base, tr)); }
        // base is the host's own libc++; only a host-format link may take it.
        if (self.format == "ELF") || (self.format == "Mach-O") { cands.push_back(base); }

        for c: string in cands {
            if LinkFS::is_file(LinkText::join(c, "libc++.so"))
            || LinkFS::is_file(LinkText::join(c, "libc++.dylib"))
            || LinkFS::is_file(LinkText::join(c, "libc++.a"))
            || LinkFS::is_file(LinkText::join(c, "libc++.lib"))
            || LinkFS::is_file(LinkText::join(c, "c++.lib")) {
                if !self._has_dir(c) { self.toolchain_lib = c; }
                return;
            }
        }
    }

    /// Deployment target and SDK version for -platform_version.
    priv fn _darwin_versions(self, msgs: ref!(vec::<LinkMessage>)) {
        self.sdk_version = self._sdk_version();

        var var_name = Toolchain::deployment_env(self.platform);
        var v = ("") if (var_name.empty()) else (LinkFS::env(var_name));
        if v.empty() { v = self._triple_version(); }
        if v.empty() { v = self.sdk_version; }
        if v.empty() {
            var how = ("a versioned triple") if (var_name.empty()) else (f"{var_name} or a versioned triple");
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"cannot determine the {self.platform} deployment target; set {how}"));
            return;
        }
        self.min_version = v;

        if self.sdk_version.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                f"cannot read the SDK version of {self.sysroot}; recording {v}. System frameworks gate behavior on the linked SDK version"));
            self.sdk_version = v;
        }
    }

    priv fn _triple_version(self) -> string {
        var nt = std::string_to_nstring(self.triple);
        var tr = llvm::Triple(llvm::StringRef(nt.raw(), nt.size()));
        if tr.getOSVersion().getMajor() == 0 { return ""; }
        if self.platform == "macos" {
            // darwinNN -> macOS version. LLVM owns the mapping.
            var v: llvm::VersionTuple;
            if !tr.getMacOSXVersion(v) { return ""; }
            return std::nstring_to_string(v.getAsString());
        }
        return std::nstring_to_string(tr.getOSVersion().getAsString());
    }

    /// SDKSettings.json's Version; else the version in the SDK's real name
    /// (MacOSX.sdk is a symlink to MacOSX14.4.sdk). "" when neither.
    priv fn _sdk_version(self) -> string {
        var text = "";
        if LinkFS::read(LinkText::join(self.sysroot, "SDKSettings.json"), text) {
            var v = Toolchain::json_string(text, "Version");
            if !v.empty() { return v; }
        }
        var name = LinkFS::filename(LinkFS::real(self.sysroot));
        if !LinkText::ends_with(name, ".sdk") { return ""; }
        var e = name.size() - 4;
        var b = e;
        while (b > 0) && (((name[b - 1] >= '0') && (name[b - 1] <= '9')) || (name[b - 1] == '.')) { b -= 1; }
        return LinkText::slice(name, b, e);
    }

    priv fn _find_gcc(self, bases: ref!(vec::<string>), spelled_arch: string) {
        var best   = "";
        var best_v = "";
        var tris   = Toolchain::gcc_triples(spelled_arch, self.arch, self.env);
        var tris64 = Toolchain::gcc_triples("x86_64", "x86_64", self.env);

        var libnames = vec::<string>();
        libnames.push_back("lib");
        libnames.push_back("lib64");

        for b: string in bases {
            for ln: string in libnames {
                var groot = LinkText::join(LinkText::join(b, ln), "gcc");
                if !LinkFS::is_dir(groot) { continue; }
                self._scan_gcc(groot, tris, "", best, best_v);
                // i386 on an x86_64 host: the 64-bit GCC's 32/ multilib.
                if self.arch == "i386" { self._scan_gcc(groot, tris64, "32", best, best_v); }
            }
        }
        self.gcc_dir = best;
    }

    priv fn _scan_gcc(self, groot: string, tris: ref!(vec::<string>), multilib: string,
                      best: ref!(string), best_v: ref!(string)) {
        for t: string in tris {
            var tdir = LinkText::join(groot, t);
            if !LinkFS::is_dir(tdir) { continue; }
            for v: string in LinkFS::list_dir(tdir) {
                if v.empty() || (v[0] < '0') || (v[0] > '9') { continue; }
                var d = LinkText::join(tdir, v);
                if !multilib.empty() { d = LinkText::join(d, multilib); }
                if !LinkFS::is_file(LinkText::join(d, "crtbegin.o")) { continue; }
                if best.empty() || Toolchain::version_less(best_v, v) {
                    best   = d;
                    best_v = v;
                }
            }
        }
    }

    priv fn _add_dir(self, d: string) {
        if !LinkFS::is_dir(d) { return; }
        var r = LinkFS::real(d);
        for s: string in self._real_dirs { if s == r { return; } }
        self._real_dirs.push_back(r);
        self.lib_dirs.push_back(d);
    }

    priv fn _has_dir(self, d: string) -> bool {
        var r = LinkFS::real(d);
        for s: string in self._real_dirs { if s == r { return true; } }
        return false;
    }

    // --- Queries (valid after resolve) ----------------------------------

    /// \p name in the crt dir, then the library dirs. Absolute names are
    /// checked as given. "" when not found.
    fn find_lib_file(self, name: string) -> string {
        if LinkText::starts_with(name, "/") {
            return (name) if (LinkFS::is_file(name)) else ("");
        }
        if !self.crt_dir.empty() {
            var p = LinkText::join(self.crt_dir, name);
            if LinkFS::is_file(p) { return p; }
        }
        for d: string in self.lib_dirs {
            var p = LinkText::join(d, name);
            if LinkFS::is_file(p) { return p; }
        }
        return "";
    }

    /// crtbegin/crtend, clang's lookup order: compiler-rt's when that is the
    /// runtime and it exists, else GCC's, else the library dirs (the BSDs
    /// ship them in base). \p variant is "", "S" or "T". "" when none: a
    /// target without them links without them.
    fn crt_object(self, stem: string, variant: string) -> string {
        if (self.rtlib == "compiler-rt") && (!self.rt_dir.empty()) {
            var p = LinkText::join(self.rt_dir, f"clang_rt.{stem}{self.rt_suffix}.o");
            if LinkFS::is_file(p) { return p; }
        }
        if !self.gcc_dir.empty() {
            var p = LinkText::join(self.gcc_dir, f"{stem}{variant}.o");
            if LinkFS::is_file(p) { return p; }
        }
        return self.find_lib_file(f"{stem}{variant}.o");
    }

    /// --print-dirs.
    fn describe(self) -> vec::<string> {
        var out = vec::<string>();
        out.push_back(f"target:          {self.triple}");
        out.push_back(f"sysroot:         {self.sysroot} ({self.style})");
        if self.has_manifest { out.push_back(f"manifest:        {self.manifest.path}"); }
        if self.format == "Mach-O" {
            out.push_back(f"platform:        {self.platform} {self.min_version} (SDK {self.sdk_version})");
            out.push_back(f"arch:            {self.darwin_arch}");
            out.push_back(f"rtlib:           {self.rtlib}");
            out.push_back(f"builtins:        {Toolchain::or_none(self.builtins)}");
            out.push_back(f"toolchain lib:   {Toolchain::or_none(self.toolchain_lib)}");
        } else if self.format == "COFF" {
            out.push_back(f"libc:            {self.libc}");
            out.push_back(f"rtlib:           {self.rtlib}");
            out.push_back(f"unwindlib:       {self.unwindlib}");
            out.push_back(f"builtins:        {Toolchain::or_none(self.builtins)}");
            out.push_back(f"gcc install:     {Toolchain::or_none(self.gcc_dir)}");
            out.push_back(f"crt dir:         {Toolchain::or_none(self.crt_dir)}");
            out.push_back(f"toolchain lib:   {Toolchain::or_none(self.toolchain_lib)}");
            if self.libc == "mingw" { out.push_back(f"emulation:       {Toolchain::or_none(self.emulation)}"); }
        } else if self.format == "Wasm" {
            out.push_back(f"libc:            {Toolchain::or_none(self.libc)}");
            out.push_back(f"rtlib:           {self.rtlib}");
            out.push_back(f"unwindlib:       {self.unwindlib}");
            out.push_back(f"builtins:        {Toolchain::or_none(self.builtins)}");
            out.push_back(f"crt dir:         {Toolchain::or_none(self.crt_dir)}");
            out.push_back(f"toolchain lib:   {Toolchain::or_none(self.toolchain_lib)}");
            out.push_back(f"emulation:       {self.emulation}");
        } else {
            out.push_back(f"libc:            {Toolchain::or_none(self.libc)}");
            out.push_back(f"rtlib:           {self.rtlib}");
            out.push_back(f"unwindlib:       {self.unwindlib}");
            out.push_back(f"builtins:        {Toolchain::or_none(self.builtins)}");
            out.push_back(f"gcc install:     {Toolchain::or_none(self.gcc_dir)}");
            out.push_back(f"crt dir:         {Toolchain::or_none(self.crt_dir)}");
            out.push_back(f"toolchain lib:   {Toolchain::or_none(self.toolchain_lib)}");
            out.push_back(f"emulation:       {Toolchain::or_none(self.emulation)}");
            out.push_back(f"dynamic linker:  {Toolchain::or_none(self.dynamic_linker)}");
        }
        out.push_back("library search:");
        for d: string in self.lib_dirs { out.push_back(f"  {d}"); }
        return out;
    }

    // --- Target tables ----------------------------------------------------

    static fn canon_arch(a: string) -> string {
        if a == "amd64" { return "x86_64"; }
        if (a == "i486") || (a == "i586") || (a == "i686") { return "i386"; }
        if a == "arm64"   { return "aarch64"; }
        if a == "ppc64le" { return "powerpc64le"; }
        if a == "ppc64"   { return "powerpc64"; }
        if LinkText::starts_with(a, "armv") || LinkText::starts_with(a, "thumb") { return "arm"; }
        return a;
    }

    static fn libc_of(os: string, env: string) -> string {
        if LinkText::contains(env, "musl") { return "musl"; }
        if LinkText::starts_with(os, "freebsd") || LinkText::starts_with(os, "netbsd")
        || LinkText::starts_with(os, "openbsd") { return "bsd"; }
        if LinkText::starts_with(os, "linux") { return "glibc"; }
        return "";
    }

    static fn os_dir(os: string) -> string {
        if LinkText::starts_with(os, "linux")   { return "linux";   }
        if LinkText::starts_with(os, "freebsd") { return "freebsd"; }
        if LinkText::starts_with(os, "netbsd")  { return "netbsd";  }
        if LinkText::starts_with(os, "openbsd") { return "openbsd"; }
        if LinkText::starts_with(os, "windows") || LinkText::starts_with(os, "mingw") { return "windows"; }
        if LinkText::starts_with(os, "wasi") { return "wasi"; }
        return "";
    }

    /// Debian-style multiarch directory name, or "" off Linux.
    static fn multiarch(a: string, os: string, env: string) -> string {
        if !LinkText::starts_with(os, "linux") { return ""; }
        var e = env;
        if e.empty() { e = "gnu"; }
        return f"{a}-linux-{e}";
    }

    /// "" lets lld infer the emulation from the first object.
    static fn emulation_for(a: string, os: string, env: string) -> string {
        var fbsd = LinkText::starts_with(os, "freebsd");
        if a == "x86_64" {
            if env == "gnux32" { return "elf32_x86_64"; }
            return ("elf_x86_64_fbsd") if (fbsd) else ("elf_x86_64");
        }
        if a == "i386"        { return ("elf_i386_fbsd") if (fbsd) else ("elf_i386"); }
        if a == "aarch64"     { return ("aarch64elf") if (fbsd) else ("aarch64linux"); }
        if a == "aarch64_be"  { return "aarch64linuxb"; }
        if a == "arm"         { return "armelf_linux_eabi"; }
        if a == "riscv64"     { return "elf64lriscv"; }
        if a == "riscv32"     { return "elf32lriscv"; }
        if a == "powerpc64le" { return "elf64lppc"; }
        if a == "powerpc64"   { return "elf64ppc"; }
        if a == "s390x"       { return "elf64_s390"; }
        if a == "loongarch64" { return "elf64loongarch"; }
        return "";
    }

    static fn dynamic_linker_for(a: string, os: string, env: string, libc: string) -> string {
        if LinkText::starts_with(os, "freebsd") { return "/libexec/ld-elf.so.1"; }
        if LinkText::starts_with(os, "netbsd")  { return "/usr/libexec/ld.elf_so"; }
        if LinkText::starts_with(os, "openbsd") { return "/usr/libexec/ld.so"; }

        var hf = LinkText::contains(env, "hf");
        if libc == "musl" {
            var ma = a;
            if a == "arm" { ma = ("armhf") if (hf) else ("arm"); }
            return f"/lib/ld-musl-{ma}.so.1";
        }
        if libc != "glibc" { return ""; }

        if a == "x86_64" {
            return ("/libx32/ld-linux-x32.so.2") if (env == "gnux32") else ("/lib64/ld-linux-x86-64.so.2");
        }
        if a == "i386"        { return "/lib/ld-linux.so.2"; }
        if a == "aarch64"     { return "/lib/ld-linux-aarch64.so.1"; }
        if a == "aarch64_be"  { return "/lib/ld-linux-aarch64_be.so.1"; }
        if a == "arm"         { return ("/lib/ld-linux-armhf.so.3") if (hf) else ("/lib/ld-linux.so.3"); }
        if a == "riscv64"     { return "/lib/ld-linux-riscv64-lp64d.so.1"; }
        if a == "riscv32"     { return "/lib/ld-linux-riscv32-ilp32d.so.1"; }
        if a == "powerpc64le" { return "/lib64/ld64.so.2"; }
        if a == "powerpc64"   { return "/lib64/ld64.so.1"; }
        if a == "s390x"       { return "/lib/ld64.so.1"; }
        if a == "loongarch64" { return "/lib64/ld-linux-loongarch-lp64d.so.1"; }
        return "";
    }

    static fn is_mingw(triple: string) -> bool {
        var nt = std::string_to_nstring(triple);
        var tr = llvm::Triple(llvm::Triple::normalize(llvm::StringRef(nt.raw(), nt.size())));
        return tr.isWindowsGNUEnvironment();
    }

    /// The -m that routes a GNU-flavor lld link to its MinGW driver.
    static fn pe_emulation_for(a: string) -> string {
        if a == "x86_64"  { return "i386pep";  }
        if a == "i386"    { return "i386pe";   }
        if a == "aarch64" { return "arm64pe";  }
        if a == "arm"     { return "thumb2pe"; }
        return "";
    }

    static fn is_msvc(triple: string) -> bool {
        var nt = std::string_to_nstring(triple);
        var tr = llvm::Triple(llvm::Triple::normalize(llvm::StringRef(nt.raw(), nt.size())));
        return tr.isWindowsMSVCEnvironment();
    }

    /// lld-link -machine.
    static fn msvc_machine(a: string) -> string {
        if a == "x86_64"  { return "x64";   }
        if a == "i386"    { return "x86";   }
        if a == "aarch64" { return "arm64"; }
        if a == "arm"     { return "arm";   }
        return "";
    }

    /// Visual Studio and Windows Kits library subdirectory.
    static fn msvc_arch_dir(a: string) -> string {
        if a == "x86_64"  { return "x64";   }
        if a == "i386"    { return "x86";   }
        if a == "aarch64" { return "arm64"; }
        return a;
    }

    /// xwin splat library subdirectory.
    static fn xwin_arch_dir(a: string) -> string {
        if a == "i386" { return "x86";   }
        if a == "arm"  { return "aarch"; }
        return a;
    }

    /// The highest dotted-numeric entry in \p dir, or "".
    static fn newest_version(dir: string) -> string {
        if !LinkFS::is_dir(dir) { return ""; }
        var best = "";
        for v: string in LinkFS::list_dir(dir) {
            if v.empty() || (v[0] < '0') || (v[0] > '9') { continue; }
            if best.empty() || Toolchain::version_less(best, v) { best = v; }
        }
        return best;
    }

    /// Directory names a mingw-w64 tree and its GCC go under.
    static fn mingw_triples(spelled: string, a: string) -> vec::<string> {
        var out = vec::<string>();
        if a == "i386" {
            Toolchain::_push_unique(out, "i686-w64-mingw32");
            Toolchain::_push_unique(out, "i586-w64-mingw32");
        } else {
            Toolchain::_push_unique(out, f"{a}-w64-mingw32");
        }
        Toolchain::_push_unique(out, f"{spelled}-w64-mingw32");
        return out;
    }

    /// Directory names distros put a GCC install under, most specific first.
    static fn gcc_triples(spelled: string, a: string, env: string) -> vec::<string> {
        var out   = vec::<string>();
        var archs = vec::<string>();
        if a == "i386" {
            archs.push_back("i686");
            archs.push_back("i586");
            archs.push_back("i486");
            archs.push_back("i386");
        } else {
            archs.push_back(a);
            if spelled != a { archs.push_back(spelled); }
        }
        var e = env;
        if e.empty() { e = "gnu"; }
        for x: string in archs {
            Toolchain::_push_unique(out, f"{x}-pc-linux-{e}");
            Toolchain::_push_unique(out, f"{x}-linux-{e}");
            Toolchain::_push_unique(out, f"{x}-unknown-linux-{e}");
            if e == "gnu" {
                Toolchain::_push_unique(out, f"{x}-redhat-linux");
                Toolchain::_push_unique(out, f"{x}-suse-linux");
                Toolchain::_push_unique(out, f"{x}-linux");
            }
        }
        return out;
    }

    // --- Apple tables -----------------------------------------------------

    /// The -platform_version name, or "" when \p os is not an Apple OS.
    static fn darwin_platform(os: string, env: string) -> string {
        if env == "macabi" { return "mac-catalyst"; }
        var sim = env == "simulator";
        if LinkText::starts_with(os, "macos") || LinkText::starts_with(os, "darwin") { return "macos"; }
        if LinkText::starts_with(os, "ios")     { return ("ios-simulator") if (sim) else ("ios"); }
        if LinkText::starts_with(os, "tvos")    { return ("tvos-simulator") if (sim) else ("tvos"); }
        if LinkText::starts_with(os, "watchos") { return ("watchos-simulator") if (sim) else ("watchos"); }
        if LinkText::starts_with(os, "xros") || LinkText::starts_with(os, "visionos") {
            return ("xros-simulator") if (sim) else ("xros");
        }
        if LinkText::starts_with(os, "driverkit") { return "driverkit"; }
        return "";
    }

    /// The -arch spelling. Subarchitectures ld64 distinguishes stay as
    /// spelled; aarch64 is arm64 everywhere on Apple.
    static fn darwin_arch_of(spelled: string, a: string) -> string {
        if (spelled == "arm64e") || (spelled == "arm64_32") || (spelled == "x86_64h") { return spelled; }
        if a == "aarch64" { return "arm64"; }
        return a;
    }

    /// The <os> in libclang_rt.<os>.a.
    static fn darwin_rt_os(platform: string) -> string {
        if (platform == "macos") || (platform == "mac-catalyst") { return "osx"; }
        if platform == "ios-simulator"     { return "iossim"; }
        if platform == "tvos-simulator"    { return "tvossim"; }
        if platform == "watchos-simulator" { return "watchossim"; }
        if platform == "xros-simulator"    { return "xrossim"; }
        return platform;
    }

    /// The deployment-target variable clang and xcodebuild read.
    static fn deployment_env(platform: string) -> string {
        if platform == "macos" { return "MACOSX_DEPLOYMENT_TARGET"; }
        if LinkText::starts_with(platform, "ios")     { return "IPHONEOS_DEPLOYMENT_TARGET"; }
        if LinkText::starts_with(platform, "tvos")    { return "TVOS_DEPLOYMENT_TARGET"; }
        if LinkText::starts_with(platform, "watchos") { return "WATCHOS_DEPLOYMENT_TARGET"; }
        if LinkText::starts_with(platform, "xros")    { return "XROS_DEPLOYMENT_TARGET"; }
        if platform == "driverkit" { return "DRIVERKIT_DEPLOYMENT_TARGET"; }
        return "";
    }

    /// Xcode's platform directory name: <P>.platform, <P>.sdk.
    static fn sdk_platform_name(platform: string) -> string {
        if (platform == "macos") || (platform == "mac-catalyst") { return "MacOSX"; }
        if platform == "ios"               { return "iPhoneOS"; }
        if platform == "ios-simulator"     { return "iPhoneSimulator"; }
        if platform == "tvos"              { return "AppleTVOS"; }
        if platform == "tvos-simulator"    { return "AppleTVSimulator"; }
        if platform == "watchos"           { return "WatchOS"; }
        if platform == "watchos-simulator" { return "WatchSimulator"; }
        if platform == "xros"              { return "XROS"; }
        if platform == "xros-simulator"    { return "XRSimulator"; }
        if platform == "driverkit"         { return "DriverKit"; }
        return "";
    }

    /// The SDK for \p platform, or "". SDKROOT counts only when its real
    /// name is for this platform: a macOS SDKROOT left in the environment
    /// must not satisfy an iOS link.
    static fn find_sdk(platform: string) -> string {
        var pname = Toolchain::sdk_platform_name(platform);
        if pname.empty() { return ""; }

        var sdkroot = LinkText::strip_slash(LinkFS::env("SDKROOT"));
        if (!sdkroot.empty()) && LinkFS::is_dir(sdkroot)
        && LinkText::starts_with(LinkFS::filename(LinkFS::real(sdkroot)), pname) {
            return sdkroot;
        }

        var devs = vec::<string>();
        var dd   = LinkText::strip_slash(LinkFS::env("DEVELOPER_DIR"));
        if !dd.empty() { devs.push_back(dd); }
        if LinkFS::exists("/var/db/xcode_select_link") {
            devs.push_back(LinkFS::real("/var/db/xcode_select_link"));
        }
        devs.push_back("/Library/Developer/CommandLineTools");
        devs.push_back("/Applications/Xcode.app/Contents/Developer");

        for d: string in devs {
            // Xcode nests SDKs per platform; the Command Line Tools keep a
            // flat SDKs/ with macOS only.
            var x = LinkText::join(d, f"Platforms/{pname}.platform/Developer/SDKs/{pname}.sdk");
            if LinkFS::is_dir(x) { return x; }
            var c = LinkText::join(d, f"SDKs/{pname}.sdk");
            if LinkFS::is_dir(c) { return c; }
        }
        return "";
    }

    /// The string value of top-level-looking \p key in \p text. Enough JSON
    /// for SDKSettings.json, nothing more. "" when absent.
    static fn json_string(text: string, key: string) -> string {
        var pat = "\x22" + key + "\x22";
        var i   = LinkText::find(text, pat, 0);
        while i < text.size() {
            var j = Toolchain::_skip_ws(text, i + pat.size());
            if (j < text.size()) && (text[j] == ':') {
                j = Toolchain::_skip_ws(text, j + 1);
                if (j >= text.size()) || (text[j] != '\x22') { return ""; }
                var e = LinkText::find(text, "\x22", j + 1);
                return LinkText::slice(text, j + 1, e);
            }
            i = LinkText::find(text, pat, i + 1);
        }
        return "";
    }

    // --- Shared helpers ---------------------------------------------------

    /// \brief \p triple with the float ABI the sysroots are built for made
    ///        explicit: 32-bit ARM Linux spelled with a bare gnu or musl
    ///        environment becomes gnueabihf / musleabihf.
    ///
    /// \details clang reads the float ABI off the environment alone, and a
    ///          bare gnu/musl on ARM means soft-float. That is an ABI break
    ///          against every armv7 sysroot (all hard-float, as Debian armhf
    ///          and Alpine are), and soft-float also turns __bf16 off, so
    ///          builtin's bf16 does not compile. An explicit gnueabi /
    ///          musleabi is left alone: that is a deliberate soft-float ask.
    ///          Anything else is returned exactly as spelled.
    static fn canonical_triple(triple: string) -> string {
        var nt = std::string_to_nstring(triple);
        var tt = llvm::Triple(llvm::Triple::normalize(llvm::StringRef(nt.raw(), nt.size())));
        if ((!tt.isARM()) && (!tt.isThumb())) || (!tt.isOSLinux()) { return triple; }
        var env = tt.getEnvironment();
        if env == llvm::Triple::GNU       { tt.setEnvironment(llvm::Triple::GNUEABIHF);  }
        else if env == llvm::Triple::Musl { tt.setEnvironment(llvm::Triple::MuslEABIHF); }
        else                              { return triple; }
        var full: libcxx::string = tt.getTriple();
        return string(full.c_str(), full.size());
    }

    /// Same arch, OS and environment; vendor and spelling ignored, so
    /// x86_64-linux-musl matches x86_64-unknown-linux-musl, and darwin
    /// matches macosx. Both sides are canonical_triple'd first, so an
    /// armv7-linux-musl sysroot matches the musleabihf target it is for.
    static fn same_target(a: string, b: string) -> bool {
        var na = std::string_to_nstring(Toolchain::canonical_triple(a));
        var nb = std::string_to_nstring(Toolchain::canonical_triple(b));
        var ta = llvm::Triple(llvm::Triple::normalize(llvm::StringRef(na.raw(), na.size())));
        var tb = llvm::Triple(llvm::Triple::normalize(llvm::StringRef(nb.raw(), nb.size())));
        var same_os = (ta.getOS() == tb.getOS()) || (ta.isMacOSX() && tb.isMacOSX());
        return (ta.getArch() == tb.getArch()) && same_os
            && (ta.getEnvironment() == tb.getEnvironment());
    }

    /// Dotted numeric compare: "9" < "13.2.1" < "16". Non-numeric suffixes
    /// within a component are ignored.
    static fn version_less(a: string, b: string) -> bool {
        var ia: usize = 0;
        var ib: usize = 0;
        while (ia < a.size()) || (ib < b.size()) {
            var na = Toolchain::_num(a, ia);
            var nb = Toolchain::_num(b, ib);
            if na != nb { return na < nb; }
        }
        return false;
    }

    static fn or_none(s: string) -> string { return ("(none)") if (s.empty()) else (s); }

    priv static fn _num(s: string, i: ref!(usize)) -> u32 {
        var v: u32 = 0;
        while (i < s.size()) && (s[i] >= '0') && (s[i] <= '9') {
            v = v * 10 + static_cast::<u32>(s[i] - '0');
            i += 1;
        }
        while (i < s.size()) && (s[i] != '.') { i += 1; }
        if i < s.size() { i += 1; }
        return v;
    }

    priv static fn _skip_ws(s: string, i: usize) -> usize {
        var j = i;
        while (j < s.size()) && ((s[j] == ' ') || (s[j] == '\t') || (s[j] == '\n') || (s[j] == '\r')) { j += 1; }
        return j;
    }

    priv static fn _push_unique(out: ref!(vec::<string>), s: string) {
        for x: string in out { if x == s { return; } }
        out.push_back(s);
    }

    priv static fn _split(s: string, sep: char) -> vec::<string> {
        var out = vec::<string>();
        var b: usize = 0;
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] == sep {
                out.push_back(LinkText::slice(s, b, i));
                b = i + 1;
            }
        }
        out.push_back(LinkText::slice(s, b, s.size()));
        return out;
    }
}