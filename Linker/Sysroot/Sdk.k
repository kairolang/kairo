/// --- The Kairo Project ---------------------------------- Sysroot/Sdk.k --- ///
///
///   Roots for the two families whose C library is never shipped (SysRoot.md
///   section 12): macOS, from the installed Apple SDK, and windows-msvc,
///   from an MSVC + Windows SDK splat. A port of the fast path of
///   scripts/darwin-sysroot.sh and scripts/msvc-sysroot (stage_sdk /
///   stage_msvc, the shipped overlay laid over it, emit_toml), so a
///   hand-unzipped toolchain assembles its own host's root on first use the
///   way the installer does (P743).
///
///     darwin  the SDK from --input, else SDKROOT / DEVELOPER_DIR / the
///             selected Xcode / the Command Line Tools / Xcode.app
///             (Toolchain::find_sdk), else `xcrun --show-sdk-path`. Found
///             only on a macOS host; elsewhere --input is the SDK= of the
///             script.
///     msvc    the splat from --input, else $XWIN, else the script's cache
///             (<prefix>/share/kairo/msvc-cache/splat). With none, on a
///             Windows host with Visual Studio's C++ tools, the script
///             itself runs (its PowerShell half reads VS + the Windows Kits
///             through vswhere and the registry; that is not ported). With
///             neither, a refusal naming the command: the splat is a
///             licensed Microsoft download, never fetched silently.
///
///   Our half (libc++, compiler-rt builtins) is the prebuilt overlay in
///   <prefix>/share/kairo/sdk-overlays/<family>-<arch>, or the directory
///   beside the share tree (a development tree's build/sdk-overlays). With
///   no overlay (arm64e, an archive built without one) the refusal names the
///   script's full build, which needs cmake and ninja.
///
///   Roots go in the sysroot cache like generated ones, keyed on the SDK
///   (its real path and SDKSettings.json, or the splat's path and stamp),
///   the overlay and the toolchain version: a new Xcode or a new release
///   assembles a fresh root, a repeat build is a by-name lookup.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::Text::LinkText
import API::Toolchain::Toolchain
import Sysroot::Cache::{
    SysCache,
    SysLock,
}
import Sysroot::Names::SysTarget
import Sysroot::Outcome::SysOutcome
import Sysroot::Share::ShareTree
import Sysroot::SysRun::SysRun
import Sysroot::SysUtil::{
    SysJsonField,
    SysUtil,
}
import std::env
import std::io

pub class SysSdk {
    /// Whether \p t is a family this file assembles instead of the
    /// generator's stages.
    pub static fn handles(t: *SysTarget) -> bool {
        return t->family == "darwin" || t->family == "windows-msvc"
    }

    /// <prefix>/share/kairo/sdk-overlays, else sdk-overlays beside the
    /// share tree; "" for neither.
    pub static fn overlays() -> string {
        var prefix = LinkFS::parent(LinkFS::parent(env::exe_path()))
        var dir    = LinkText::join(prefix, "share/kairo/sdk-overlays")
        if LinkFS::is_dir(dir) {
            return dir
        }

        var share = ShareTree::locate("")
        dir = LinkText::join(LinkFS::parent(LinkText::strip_slash(share)), "sdk-overlays")
        return if (LinkFS::is_dir(dir)) => (dir) else => ""
    }

    /// The toolchain's prefix: the directory above bin/.
    pub static fn prefix() -> string {
        return LinkFS::parent(LinkFS::parent(env::exe_path()))
    }

    /// The macOS SDK to stage: \p input when given, else the installed one
    /// (macOS hosts only). "" for none.
    pub static fn find_macos_sdk(const input: string) -> string {
        if !input.empty() {
            return LinkFS::real(input)
        }

        var mac = false
        eval if defined!(__APPLE__) {
            mac = true
        }

        if !mac {
            return ""
        }

        var sdk = Toolchain::find_sdk("macos")
        if sdk.empty()
            && LinkFS::exists("/var/db/xcode_select_link")
            && LinkFS::is_file("/usr/bin/xcrun") {
            // Only with developer tools selected: on a bare Mac the xcrun
            // shim pops the Command Line Tools installer instead of failing.
            var log  = LinkFS::temp_file("ksys-xcrun", ".txt")
            var argv = cxx::std::vector<string>()
            argv.push_back("/usr/bin/xcrun")
            argv.push_back("--sdk")
            argv.push_back("macosx")
            argv.push_back("--show-sdk-path")
            var text = ""
            if SysRun::run(&argv, log) == 0 && LinkFS::read(log, &text) {
                sdk = LinkText::trim(text)
            }

            LinkFS::remove(log)
        }

        // MacOSX.sdk is a link to MacOSX26.x.sdk: the key and the root's
        // provenance name the real one.
        return if (sdk.empty()) => ("") else => LinkFS::real(sdk)
    }

    /// xwin's arch directory name for \p arch.
    pub static fn msvc_arch(const arch: string) -> string {
        if arch == "i686" {
            return "x86"
        }

        return arch
    }

    /// An xwin splat with the SDK headers and \p xa's CRT: \p input, $XWIN,
    /// or the script's cached splat. "" for none.
    pub static fn find_msvc_splat(const input: string, const xa: string) -> string {
        var cands = cxx::std::vector<string>()
        if !input.empty() {
            cands.push_back(input)
        } else {
            var x = LinkFS::env("XWIN")
            if !x.empty() {
                cands.push_back(x)
            }

            var mc = LinkFS::env("MSVC_CACHE")
            if mc.empty() {
                mc = LinkText::join(SysSdk::prefix(), "share/kairo/msvc-cache")
            }

            cands.push_back(LinkText::join(mc, "splat"))
        }

        for var c: string in cands {
            var um = LinkText::join(c, "sdk/include/um")
            var hd = LinkFS::is_file(LinkText::join(um, "Windows.h"))
                || LinkFS::is_file(LinkText::join(um, "windows.h"))
            if hd && LinkFS::is_dir(LinkText::join(c, f"crt/lib/{xa}")) {
                return LinkFS::real(c)
            }
        }

        return ""
    }

    /// The cached root for \p t, assembled first if need be; \p path
    /// receives it. \p input is ksys's --input (the SDK or splat), "" to
    /// discover one.
    pub static fn ensure(@inout c:    SysCache,
                         t:           *SysTarget,
                         const input: string,
                         const tools: string,
                         @inout path: string,
                         @inout out:  SysOutcome) -> bool {
        if c.root.empty() {
            return out.refuse(
                "no cache directory for sysroots",
                "set KAIRO_SYSROOT_CACHE (or KAIRO_CACHE_DIR, XDG_CACHE_HOME, HOME)",
            )
        }

        var darwin = t->family == "darwin"
        var arch   = t->arch
        var family = if (darwin) => ("darwin") else => "msvc"
        var ovs    = SysSdk::overlays()
        var ov     = if (ovs.empty()) => ("") else => LinkText::join(ovs, f"{family}-{arch}")
        var ov_lib = if (darwin) => ("usr/lib/libc++.a") else => "lib/libc++.lib"
        var script = if (darwin) => (f"darwin-sysroot.sh {arch}") else => f"msvc-sysroot.ps1 {arch}"
        var scripts = LinkText::join(SysSdk::prefix(), "scripts")

        // Staged before (by the driver's first use, or by hand with --input)
        // and nothing to stage from now: that root still serves.
        var have = c.lookup(t->name)
        var src  = ""
        var xa   = SysSdk::msvc_arch(arch)
        if input.empty() && !have.empty() && LinkFS::is_file(LinkText::join(have, "SYSROOT.toml")) {
            src = if (darwin) => (SysSdk::find_macos_sdk(""))
                  else => SysSdk::find_msvc_splat("", xa)
            if src.empty() {
                path = have
                return true
            }
        }

        if darwin {
            src = SysSdk::find_macos_sdk(input)
            if src.empty() {
                return out.refuse(
                    f"no macOS SDK found for {t->name}",
                    "install the Command Line Tools (xcode-select --install) or Xcode, or set SDKROOT=<path to MacOSX.sdk>",
                )
            }

            if !LinkFS::is_file(LinkText::join(src, "SDKSettings.json"))
                || !LinkFS::is_file(LinkText::join(src, "usr/lib/libSystem.tbd")) {
                return out.refuse(
                    f"{src} is not a macOS SDK (no SDKSettings.json or usr/lib/libSystem.tbd)",
                    "",
                )
            }
        } else {
            src = SysSdk::find_msvc_splat(input, xa)
            if src.empty() && input.empty() {
                var vs = SysSdk::_visual_studio()
                if !vs.empty() {
                    return SysSdk::_run_msvc_script(&c, t, vs, tools, &path, &out)
                }
            }

            if src.empty() {
                var ps = LinkText::join(scripts, "msvc-sysroot.ps1")
                return out.refuse(
                    f"no sysroot for {t->name}: no Visual Studio C++ tools and no MSVC splat were found",
                    f"run: powershell -ExecutionPolicy Bypass -File \x22{ps}\x22 {arch} (it downloads Microsoft\x27s CRT and Windows SDK after you accept their license), or install the Visual Studio Build Tools, or set XWIN=<an xwin splat>",
                )
            }
        }

        if ov.empty() || !LinkFS::is_file(LinkText::join(ov, ov_lib)) {
            return out.refuse(
                f"no prebuilt libc++ overlay for {t->name} in this toolchain",
                f"build the root from source with {scripts}/{script} --from-source (needs cmake and ninja)",
            )
        }

        var key  = SysSdk::_key(t, src, ov)
        var lock = SysLock()
        if !lock.acquire(c.lock_path(key)) {
            return out.fail(f"cannot lock {c.lock_path(key)}", "")
        }

        var dir = c.sysroot_dir(key)
        if !LinkFS::is_file(LinkText::join(dir, ".ok")) {
            var tmp = dir + ".tmp"
            LinkFS::remove_tree(tmp)
            if !LinkFS::make_dirs(tmp) {
                return out.fail(f"cannot create {tmp}", "")
            }

            var ok = if (darwin) => (SysSdk::_stage_darwin(src, tmp, &out))
                     else => SysSdk::_stage_msvc(src, xa, tmp, &out)
            if ok {
                ok = SysSdk::_lay_overlay(ov, tmp, darwin, &out)
            }

            if ok {
                ok = SysSdk::_write_toml(t, xa, tmp, &out)
            }

            if ok {
                ok = SysSdk::_check(t, tmp, darwin, &out)
            }

            if ok {
                ok = SysSdk::_validate(t, tmp, tools, &out)
            }

            if !ok {
                LinkFS::remove_tree(tmp)
                return false
            }

            LinkFS::write(LinkText::join(tmp, ".ok"), "")
            LinkFS::remove_tree(dir)
            if !LinkFS::rename(tmp, dir) {
                LinkFS::remove_tree(tmp)
                return out.fail(f"cannot move {tmp} to {dir}", "")
            }

            // The scripts' closing note, on stderr (ensure's stdout is the
            // path): the root is the user's licensed SDK, not ours to ship.
            if darwin {
                io::eprintln(
                    "They contain Apple\x27s SDK: keep them local, never redistribute them.",
                )
            } else {
                io::eprintln(
                    "They contain Microsoft\x27s CRT and SDK: keep them local, never redistribute them.",
                )
            }
        }

        if !c.publish(t->name, key) {
            return out.fail(f"cannot write {c.root}/by-name/{t->name}", "")
        }

        path = dir
        return true
    }

    /// # Staging

    /// darwin-sysroot.sh stage_sdk: SDKSettings, usr/include without
    /// Apple's libc++ headers, usr/lib's .tbd stubs without Apple's libc++
    /// (the linker prefers a stub over our .a in the same dir) and swift,
    /// the frameworks without swift's module files. Files are hard links
    /// where the filesystem allows (the SDK is read-only to us, and every
    /// later write here replaces a file rather than writing through it).
    priv static fn _stage_darwin(const sdk:  string,
                                 const dst:  string,
                                 @inout out: SysOutcome) -> bool {
        var none     = cxx::std::vector<string>()
        var settings = cxx::std::vector<string>()
        settings.push_back("SDKSettings.json")
        settings.push_back("SDKSettings.plist")
        for var f: string in settings {
            var s = LinkText::join(sdk, f)
            if LinkFS::is_file(s) && !SysRun::put_file(s, LinkText::join(dst, f), false) {
                return out.fail(f"cannot copy {s}", "")
            }
        }

        var inc_skip = cxx::std::vector<string>()
        inc_skip.push_back("c++")
        if !SysSdk::_copy(
            LinkText::join(sdk, "usr/include"),
            LinkText::join(dst, "usr/include"),
            &inc_skip,
            &none,
            0,
        ) {
            return out.fail(f"cannot copy {sdk}/usr/include", "")
        }

        var lib_skip = cxx::std::vector<string>()
        lib_skip.push_back("swift")
        lib_skip.push_back("libc++*.tbd")
        if !SysSdk::_copy(
            LinkText::join(sdk, "usr/lib"),
            LinkText::join(dst, "usr/lib"),
            &lib_skip,
            &none,
            0,
        ) {
            return out.fail(f"cannot copy {sdk}/usr/lib", "")
        }

        var fw = LinkText::join(sdk, "System/Library/Frameworks")
        if LinkFS::is_dir(fw) {
            var swift = cxx::std::vector<string>()
            swift.push_back("*.swiftmodule")
            swift.push_back("*.swiftinterface")
            swift.push_back("*.swiftdoc")
            swift.push_back("*.abi.json")
            if !SysSdk::_copy(
                fw,
                LinkText::join(dst, "System/Library/Frameworks"),
                &none,
                &swift,
                0,
            ) {
                return out.fail(f"cannot copy {fw}", "")
            }
        }

        return true
    }

    /// msvc-sysroot stage_msvc: the CRT and SDK headers for every arch,
    /// the libraries for this one, under <root>/msvc. Links are kept:
    /// xwin's case-variant links (Windows.h -> windows.h) are what let the
    /// SDK's mixed-case includes resolve on a case-sensitive filesystem.
    priv static fn _stage_msvc(const splat: string,
                               const xa:    string,
                               const dst:   string,
                               @inout out:  SysOutcome) -> bool {
        var none = cxx::std::vector<string>()
        var m    = LinkText::join(dst, "msvc")
        var dirs = cxx::std::vector<string>()
        dirs.push_back("crt/include")
        dirs.push_back(f"crt/lib/{xa}")
        dirs.push_back("sdk/include/ucrt")
        dirs.push_back("sdk/include/um")
        dirs.push_back("sdk/include/shared")
        dirs.push_back("sdk/include/winrt")
        dirs.push_back(f"sdk/lib/um/{xa}")
        dirs.push_back(f"sdk/lib/ucrt/{xa}")
        for var d: string in dirs {
            var s = LinkText::join(splat, d)
            if !LinkFS::is_dir(s) {
                if d == "sdk/include/winrt" {
                    continue
                }

                return out.refuse(f"{splat} has no {d}: re-run xwin with --arch including {xa}", "")
            }

            if !SysSdk::_copy(s, LinkText::join(m, d), &none, &none, 0) {
                return out.fail(f"cannot copy {s}", "")
            }
        }

        return true
    }

    /// The overlay over the staged SDK (darwin: the whole tree; msvc: its
    /// include/, lib/ and compiler-rt/, as copy_overlay does).
    priv static fn _lay_overlay(const ov:   string,
                                const dst:  string,
                                darwin:     bool,
                                @inout out: SysOutcome) -> bool {
        var none = cxx::std::vector<string>()
        if darwin {
            if !SysRun::copy_tree(ov, dst, &none) {
                return out.fail(f"cannot copy the overlay {ov}", "")
            }

            return true
        }

        var parts = cxx::std::vector<string>()
        parts.push_back("include")
        parts.push_back("lib")
        parts.push_back("compiler-rt")
        for var d: string in parts {
            if !SysRun::copy_tree(LinkText::join(ov, d), LinkText::join(dst, d), &none) {
                return out.fail(f"cannot copy the overlay {ov}/{d}", "")
            }
        }

        return true
    }

    /// SYSROOT.toml, as the scripts' emit_toml writes it. No clang_triple:
    /// the driver would put it in place of the user's --target, and
    /// `arm64-apple-macosx13.0` must stay 13.0 (a bare one already gets its
    /// floor from Toolchain::with_os_floor).
    priv static fn _write_toml(t:          *SysTarget,
                               const xa:   string,
                               const dst:  string,
                               @inout out: SysOutcome) -> bool {
        var s = ""
        if t->family == "darwin" {
            s += f"triple        = \x22{t->name}\x22\n"
            s += "llvm_version  = \x2222.1.0\x22\n"
            s += "family        = \x22darwin\x22\n"
            s += "sysroot       = \x22.\x22\n"
            s += "resource_dir  = \x22clang\x22\n"
            s += "redistributable = false\n"
            s += "include_dirs  = [\x22usr/include/c++/v1\x22, \x22usr/include\x22]\n"
            s += "lib_dirs      = [\x22usr/lib\x22]\n"
            s += "has_libcxx    = true\n"
            s += "static        = false\n"
            s += "crt_startup   = []\n"
            s += "crt_end       = []\n"
            s += "libc_link     = [\x22-lSystem\x22]\n"
            s += "libcxx_link   = [\x22-lc++\x22]\n"
            s += "rtlib         = \x22compiler-rt\x22\n"
            s += "linker        = \x22lld\x22\n"
            s += "cc_isolation  = [\x22-nostdlibinc\x22, \x22-nostdinc++\x22]\n"
        } else {
            s += f"triple        = \x22{t->name}\x22\n"
            s += "llvm_version  = \x2222.1.0\x22\n"
            s += "family        = \x22windows-msvc\x22\n"
            s += "sysroot       = \x22.\x22\n"
            s += "include_dirs  = [\x22include/c++/v1\x22, \x22msvc/crt/include\x22, \x22msvc/sdk/include/ucrt\x22, \x22msvc/sdk/include/um\x22, \x22msvc/sdk/include/shared\x22]\n"
            s += f"lib_dirs      = [\x22lib\x22, \x22msvc/crt/lib/{xa}\x22, \x22msvc/sdk/lib/um/{xa}\x22, \x22msvc/sdk/lib/ucrt/{xa}\x22]\n"
            s += "has_libcxx    = true\n"
            s += "static        = true\n"
            s += "crt_startup   = []\n"
            s += "crt_end       = []\n"
            s += "libc_link     = [\x22libcmt.lib\x22, \x22libvcruntime.lib\x22, \x22libucrt.lib\x22, \x22oldnames.lib\x22, \x22kernel32.lib\x22, \x22user32.lib\x22, \x22advapi32.lib\x22, \x22shell32.lib\x22, \x22uuid.lib\x22]\n"
            s += "libcxx_link   = [\x22libc++.lib\x22, \x22libcpmt.lib\x22]\n"
            s += "rtlib         = \x22compiler-rt\x22\n"
            s += "linker        = \x22lld-link\x22\n"
            s += "resource_dir  = \x22compiler-rt\x22\n"
            s += "msvc_crt      = \x22static\x22\n"
            s += "local_only    = [\x22msvc\x22]\n"
            s += "cc_defines    = [\x22_CRT_STDIO_ISO_WIDE_SPECIFIERS\x22]\n"
            s += "cc_isolation  = [\x22-nostdlibinc\x22, \x22-nostdinc++\x22]\n"
        }

        var p = LinkText::join(dst, "SYSROOT.toml")
        if !LinkFS::write(p, s) {
            return out.fail(f"cannot write {p}", "")
        }

        return true
    }

    /// The scripts' structural checks: a half-staged root fails here, not in
    /// the user's first compile.
    priv static fn _check(t:          *SysTarget,
                          const r:    string,
                          darwin:     bool,
                          @inout out: SysOutcome) -> bool {
        var need = cxx::std::vector<string>()
        if darwin {
            need.push_back("usr/include/stdio.h")
            need.push_back("usr/include/c++/v1/vector")
            need.push_back("usr/lib/libSystem.tbd")
            need.push_back("usr/lib/libc++.a")
        } else {
            need.push_back("include/c++/v1/vector")
            need.push_back("include/c++/v1/__config_site")
            need.push_back("lib/libc++.lib")
        }

        for var n: string in need {
            if !LinkFS::is_file(LinkText::join(r, n)) {
                return out.fail(f"{t->name}: the staged root has no {n}", "")
            }
        }

        if darwin {
            if !LinkFS::is_dir(LinkText::join(r, "usr/lib/system")) {
                return out.fail(f"{t->name}: the staged root has no usr/lib/system", "")
            }

            for var f: string in LinkFS::list_dir(LinkText::join(r, "usr/lib")) {
                if SysSdk::_glob(f, "libc++*.tbd") {
                    return out.fail(
                        f"{t->name}: Apple\x27s libc++ stub {f} leaked into the root",
                        "",
                    )
                }
            }

            return true
        }

        // A dll-import __config_site would make every libc++ use an __imp_
        // reference the static libc++.lib does not define.
        var cs = ""
        LinkFS::read(LinkText::join(r, "include/c++/v1/__config_site"), &cs)
        if !LinkText::contains(cs, "_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS") {
            return out.fail(f"{t->name}: the overlay\x27s __config_site is not static-only", "")
        }

        return true
    }

    /// A C++ compile against the root through its SYSROOT.toml alone (the
    /// scripts link one; the link is the first build's anyway, and it would
    /// put the Kairo library's first build inside this one). Skipped when a
    /// root bundled beside kcc shadows --sysroot: kcc would test that one.
    priv static fn _validate(t:           *SysTarget,
                             const r:     string,
                             const tools: string,
                             @inout out:  SysOutcome) -> bool {
        var exe = "kcc"
        eval if defined!(_WIN32) {
            exe = "kcc.exe"
        }

        var kcc     = LinkText::join(tools, exe)
        var bundled = LinkText::join(LinkFS::parent(tools), f"sysroot/{t->name}")
        if !LinkFS::is_file(kcc) || LinkFS::exists(bundled) {
            return true
        }

        var w = LinkText::join(r, ".validate")
        LinkFS::make_dirs(w)
        var src = LinkText::join(w, "t.cpp")
        LinkFS::write(
            src,
            "#include <cstdio>\n#include <stdexcept>\n#include <string>\n#include <vector>\nint main() {\n  std::vector<std::string> v{\"a\", \"b\"};\n  try { throw std::runtime_error(v[0] + v[1]); }\n  catch (const std::exception &e) { std::printf(\"%s\\n\", e.what()); }\n  return 0;\n}\n",
        )

        var ct = t->clang_triple
        if t->family == "darwin" {
            ct = f"{t->arch}-apple-macosx{Toolchain::macos_floor(t->clang_triple)}"
        }

        var log  = LinkText::join(w, "compile.log")
        var argv = cxx::std::vector<string>()
        argv.push_back(kcc)
        argv.push_back(f"--target={ct}")
        argv.push_back(f"--sysroot={r}")
        argv.push_back("--sysroot-exact")
        argv.push_back("-std=c++20")
        argv.push_back("-c")
        argv.push_back(src)
        argv.push_back("-o")
        argv.push_back(LinkText::join(w, "t.o"))
        if SysRun::run(&argv, log) != 0 {
            var keep = LinkFS::temp_file("ksys-sdk-validate", ".log")
            SysRun::put_file(log, keep, false)
            return out.fail(
                f"validation failed: kcc could not compile C++ against the staged {t->name} root",
                f"log: {keep}",
            )
        }

        LinkFS::remove_tree(w)
        return true
    }

    /// # Visual Studio

    /// The installation vswhere reports, when it has the C++ tools; "" off
    /// Windows or for none.
    priv static fn _visual_studio() -> string {
        var win = false
        eval if defined!(_WIN32) {
            win = true
        }

        if !win {
            return ""
        }

        var pf      = LinkFS::env("ProgramFiles(x86)")
        var vswhere = LinkText::join(pf, "Microsoft Visual Studio/Installer/vswhere.exe")
        if pf.empty() || !LinkFS::is_file(vswhere) {
            return ""
        }

        var log  = LinkFS::temp_file("ksys-vswhere", ".txt")
        var argv = cxx::std::vector<string>()
        argv.push_back(vswhere)
        argv.push_back("-latest")
        argv.push_back("-products")
        argv.push_back("*")
        argv.push_back("-requires")
        argv.push_back("Microsoft.VisualStudio.Component.VC.Tools.x86.x64")
        argv.push_back("-property")
        argv.push_back("installationPath")
        var text = ""
        if SysRun::run(&argv, log) != 0 || !LinkFS::read(log, &text) {
            text = ""
        }

        LinkFS::remove(log)
        var vs = LinkText::trim(text)
        var vc = LinkText::join(vs, "VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt")
        return if (!vs.empty() && LinkFS::is_file(vc)) => (vs) else => ""
    }

    /// The installed Visual Studio as the root's Microsoft half: the
    /// script's PowerShell half, which reads VS and the Windows Kits, run
    /// with OUT in the cache so the root lands there like any other.
    priv static fn _run_msvc_script(@inout c:    SysCache,
                                    t:           *SysTarget,
                                    const vs:    string,
                                    const tools: string,
                                    @inout path: string,
                                    @inout out:  SysOutcome) -> bool {
        var ps1 = LinkText::join(SysSdk::prefix(), "scripts/msvc-sysroot.ps1")
        if !LinkFS::is_file(ps1) {
            return out.refuse(f"{ps1} is missing; reinstall the toolchain", "")
        }

        var shell = SysSdk::_powershell()
        if shell.empty() {
            return out.refuse(
                "Visual Studio found, but no powershell.exe to run msvc-sysroot.ps1 with",
                "",
            )
        }

        var stamp = SysUtil::sha256_file(
            LinkText::join(vs, "VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt"),
        )

        var fields = cxx::std::vector<SysJsonField>()
        SysUtil::field(&fields, "schema", "1")
        SysUtil::field(&fields, "name", SysUtil::json_str(t->name))
        SysUtil::field(&fields, "vs", SysUtil::json_str(vs))
        SysUtil::field(&fields, "vc_tools", SysUtil::json_str(stamp))
        SysUtil::field(&fields, "tool_version", SysUtil::json_str(SysSdk::_tool_version()))
        var key = SysUtil::sha256(SysUtil::json_object(&fields))

        var lock = SysLock()
        if !lock.acquire(c.lock_path(key)) {
            return out.fail(f"cannot lock {c.lock_path(key)}", "")
        }

        var dir = c.sysroot_dir(key)
        if !LinkFS::is_file(LinkText::join(dir, ".ok")) {
            var stage = dir + ".tmp"
            LinkFS::remove_tree(stage)
            LinkFS::make_dirs(stage)
            var log = LinkText::join(c.root, f"logs/{t->name}-msvc-sysroot.log")
            LinkFS::make_dirs(LinkFS::parent(log))
            var argv = cxx::std::vector<string>()
            argv.push_back(shell)
            argv.push_back("-NoProfile")
            // A prompt (the license, in a branch this should never reach)
            // fails instead of waiting on a console nobody sees.
            argv.push_back("-NonInteractive")
            argv.push_back("-ExecutionPolicy")
            argv.push_back("Bypass")
            argv.push_back("-File")
            argv.push_back(ps1)
            argv.push_back(t->arch)
            // The script reads OUT / WORK from its environment; the driver
            // is still single-threaded here, so setting them is safe.
            var old_out  = LinkFS::env("OUT")
            var old_work = LinkFS::env("WORK")
            LinkFS::set_env("OUT", stage)
            LinkFS::set_env("WORK", stage + ".work")
            var rc = SysRun::run(&argv, log)
            LinkFS::set_env("OUT", old_out)
            LinkFS::set_env("WORK", old_work)
            LinkFS::remove_tree(stage + ".work")
            var made = LinkText::join(stage, t->name)
            if rc != 0 || !LinkFS::is_file(LinkText::join(made, "SYSROOT.toml")) {
                LinkFS::remove_tree(stage)
                return out.fail(f"msvc-sysroot.ps1 {t->arch} failed (exit {rc})", f"log: {log}")
            }

            LinkFS::write(LinkText::join(made, ".ok"), "")
            LinkFS::remove_tree(dir)
            var ok = LinkFS::rename(made, dir)
            LinkFS::remove_tree(stage)
            if !ok {
                return out.fail(f"cannot move {made} to {dir}", "")
            }

            io::eprintln(
                "They contain Microsoft\x27s CRT and SDK: keep them local, never redistribute them.",
            )
        }

        if !c.publish(t->name, key) {
            return out.fail(f"cannot write {c.root}/by-name/{t->name}", "")
        }

        path = dir
        return true
    }

    priv static fn _powershell() -> string {
        var root = LinkFS::env("SystemRoot")
        var sys  = LinkText::join(root, "System32/WindowsPowerShell/v1.0/powershell.exe")
        if !root.empty() && LinkFS::is_file(sys) {
            return sys
        }

        return ""
    }

    /// # Helpers

    priv static fn _tool_version() -> string {
        return string(unsafe ((kairo::version_string() as unsafe *const u8) as *const u8))
    }

    /// The root's key: the target, the SDK it was staged from (the macOS
    /// SDK's settings name its version; a splat has none, so its stamp), the
    /// overlay, the toolchain.
    priv static fn _key(t: *SysTarget, const src: string, const ov: string) -> string {
        var sdk = if (t->family == "darwin") => (SysUtil::sha256_file(
                      LinkText::join(src, "SDKSettings.json"),
                  ))
                  else => SysUtil::tree_stamp(LinkText::join(src, "sdk/include/um"), true)
        var rev = ""
        LinkFS::read(LinkText::join(LinkFS::parent(ov), "REVISION"), &rev)
        var fields = cxx::std::vector<SysJsonField>()
        SysUtil::field(&fields, "schema", "1")
        SysUtil::field(&fields, "name", SysUtil::json_str(t->name))
        SysUtil::field(&fields, "provider", SysUtil::json_str("user"))
        SysUtil::field(&fields, "source", SysUtil::json_str(src))
        SysUtil::field(&fields, "source_id", SysUtil::json_str(sdk))
        SysUtil::field(&fields, "overlay_revision", SysUtil::json_str(LinkText::trim(rev)))
        SysUtil::field(&fields, "overlay", SysUtil::json_str(SysUtil::tree_stamp(ov, true)))
        SysUtil::field(&fields, "tool_version", SysUtil::json_str(SysSdk::_tool_version()))
        return SysUtil::sha256(SysUtil::json_object(&fields))
    }

    /// Copies \p from into \p to, links kept, files hard-linked where
    /// possible. \p top names entries left out at the top level only,
    /// \p any at every depth (globs with at most one `*`, as tar --exclude
    /// is used by the scripts).
    priv static fn _copy(const from: string,
                         const to:   string,
                         @inout top: cxx::std::vector<string>,
                         @inout any: cxx::std::vector<string>,
                         depth:      u32) -> bool {
        if depth > 64 || !LinkFS::make_dirs(to) {
            return false
        }

        var none = cxx::std::vector<string>()
        for var name: string in LinkFS::list_dir(from) {
            if SysSdk::_any_glob(name, &top) || SysSdk::_any_glob(name, &any) {
                continue
            }

            var s    = from + "/" + name
            var d    = to + "/" + name
            var link = SysRun::read_link(s)
            if !link.empty() {
                if !SysRun::symlink(link, d) {
                    return false
                }

                continue
            }

            if LinkFS::is_dir(s) {
                if !SysSdk::_copy(s, d, &none, &any, depth + 1) {
                    return false
                }

                continue
            }

            if LinkFS::is_file(s) && !SysRun::put_file(s, d, true) {
                return false
            }
        }

        return true
    }

    priv static fn _any_glob(const name: string, @inout pats: cxx::std::vector<string>) -> bool {
        for var p: string in pats {
            if SysSdk::_glob(name, p) {
                return true
            }
        }

        return false
    }

    /// \p name against \p pat, which holds at most one `*`.
    priv static fn _glob(const name: string, const pat: string) -> bool {
        var star = LinkText::find(pat, "*", 0)
        if star >= pat.size() {
            return name == pat
        }

        var head = LinkText::slice(pat, 0, star)
        var tail = LinkText::slice(pat, star + 1, pat.size())
        return name.size() >= head.size() + tail.size()
            && LinkText::starts_with(name, head)
            && LinkText::ends_with(name, tail)
    }
}
