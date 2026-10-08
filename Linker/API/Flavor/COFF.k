/// --- The Kairo Project ------------------ Linker/API/Flavor/COFF.k ------ ///
///
///   \brief LinkJob + Toolchain -> lld-link argv for MSVC targets
///          (<arch>-windows-msvc). Decides nothing the Toolchain did not
///          resolve and runs nothing. MinGW-w64 targets go through MinGW.k;
///          this is lld's coff driver proper.
///
///   Options are spelled with '-', never '/': lld-link takes both, and on
///   a POSIX host a '/'-spelled option is one typo from a path. Inputs are
///   absolute POSIX paths and go in as they are: the option table hands a
///   '/'-led argument that names no option back as an input.
///
///   Order follows clang's MSVC linker order, so a line from here lines up
///   against `clang++ --target=x86_64-pc-windows-msvc -fuse-ld=lld -###`:
///
///     options, -machine, -out, -libpath, behavior, objects, user libs,
///     default libs
///
///   There is no crt object. mainCRTStartup lives in the CRT library, and
///   lld-link infers the entry and the subsystem from main, WinMain or
///   DllMain.
///
///   \par CRT
///     Static by default (/MT: libcmt, libvcruntime, libucrt), which is also
///     what clang's objects ask for through /DEFAULTLIB. The dynamic CRT
///     needs vcruntime140.dll, which a clean Windows install lacks. Linking
///     a CRT by name (-l msvcrt -l vcruntime -l ucrt) switches to it and
///     -nodefaultlib's the static set; the objects must be compiled to
///     match (-fms-runtime-lib=dll), or two CRTs end up in one image. A
///     manifest's libc_link overrides all of this.
///
///   \par libc++
///     On MSVC libc++ sits on vcruntime's exception ABI: no libc++abi, no
///     unwinder. libc++.lib (static) is preferred to c++.lib (the import
///     library for c++.dll), for the same reason as the CRT.
///
///   \par Debug info
///     -debug unless stripping. Without it lld-link drops every .debug$
///     section, so the ELF default (keep it) maps to a PDB beside the
///     output.
///
///   Output shape:
///     default     executable; -debug writes <out>.pdb
///     --shared    -dll; the import library <out>.lib comes with it
///     --static    nothing to do: the CRT is already static
///
///   No PE meaning, dropped: hash style, relro, -z now, noexecstack,
///   eh-frame-hdr, compressed debug sections, PIE (every image is
///   -dynamicbase). Diagnosed where the drop changes the output.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Config::Linker::*;
import Linker::API::Text::*;
import Linker::API::FS::*;
import Linker::API::LinkDiag::*;
import Linker::API::LinkJob::*;
import Linker::API::Toolchain::*;

class COFFArgs {
    static fn build(job: ref!(LinkJob), tc: ref!(Toolchain),
                    argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) -> bool {
        var errs0 = LinkDiag::error_count(msgs);
        var o     = job.opts;

        if job.output.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, "link: no output path"));
            return false;
        }
        if o->shared && o->static_link {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, "--shared and --static are mutually exclusive"));
            return false;
        }
        if (!o->shared) && o->no_entry {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "--no-entry: a PE executable needs an entry point; only a DLL can go without one"));
            return false;
        }

        var machine = Toolchain::msvc_machine(tc.arch);
        if machine.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, f"lld-link has no machine type for {tc.arch}"));
            return false;
        }

        var shared  = o->shared;
        var no_crt  = o->no_crt || o->freestanding;
        var no_libs = o->no_default_libs || o->freestanding;

        if no_crt && (!shared) && o->entry.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "without the CRT there is no mainCRTStartup; pass --entry"));
            return false;
        }

        COFFArgs::_ignored(o, msgs);

        // --- options -------------------------------------------------------
        argv.push_back("lld-link");
        argv.push_back("-nologo");
        argv.push_back("-errorlimit:0");
        if job.threads > 0 { argv.push_back(f"-threads:{job.threads}"); }
        argv.push_back(f"-machine:{machine}");
        if shared { argv.push_back("-dll"); }
        argv.push_back(f"-out:{job.output}");

        // With the CRT, -entry would skip its initialization; the entry flag
        // only names the entry when there is no CRT to own it.
        if shared && o->no_entry {
            argv.push_back("-noentry");
        } else if no_crt && (!o->entry.empty()) {
            argv.push_back(f"-entry:{o->entry}");
        }
        // Objects carry /DEFAULTLIB for the CRT they were compiled against.
        if no_crt { argv.push_back("-nodefaultlib"); }

        // --- search path, user's first ----------------------------------------
        for d: string in o->lib_dirs { argv.push_back(f"-libpath:{d}"); }
        if !tc.toolchain_lib.empty() { argv.push_back(f"-libpath:{tc.toolchain_lib}"); }
        for d: string in tc.lib_dirs { argv.push_back(f"-libpath:{d}"); }

        // --- behavior -------------------------------------------------------
        if (!o->strip) && (!o->strip_debug) { argv.push_back("-debug"); }
        if o->build_id == "none"     { argv.push_back("-build-id:no"); }
        else if !o->build_id.empty() { argv.push_back("-build-id"); }

        if o->f_gc_sections == 1 { argv.push_back("-opt:ref");   }
        if o->f_gc_sections == 0 { argv.push_back("-opt:noref"); }
        // lld-link turns ICF on whenever -opt:ref is on. Kairo's --icf is
        // opt-in on every other target, so it is spelled out both ways.
        if o->icf {
            if o->icf_mode == "all"       { argv.push_back("-opt:icf"); }
            else if o->icf_mode == "safe" { argv.push_back("-opt:safeicf"); }
            else {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"unknown --icf-mode {o->icf_mode}; expected safe or all"));
            }
        } else {
            argv.push_back("-opt:noicf");
        }
        if !o->map_file.empty() { argv.push_back(f"-map:{o->map_file}"); }
        for f: string in o->ld_flags { argv.push_back(f); }

        // --- inputs ----------------------------------------------------------
        for obj: string in job.objects { argv.push_back(obj); }
        for spec: string in o->link_libs { COFFArgs::_user_lib(spec, argv, msgs); }

        if !no_libs { COFFArgs::_default_libs(tc, o, no_crt, argv, msgs); }

        return LinkDiag::error_count(msgs) == errs0;
    }

    priv static fn _ignored(o: *LinkerOptions, msgs: ref!(vec::<LinkMessage>)) {
        if !o->linker_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "PE has no linker scripts; place sections with -merge, -section or -order through ld flags"));
        }
        if !o->version_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "version scripts are ELF-only; control DLL exports with a .def file passed as an input, or __declspec(dllexport)"));
        }
        if o->export_dynamic {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "--export-dynamic has no MSVC equivalent: an image exports what a .def file or __declspec(dllexport) names"));
        }
        if !o->rpath.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "Windows has no rpath: DLLs load from the executable's directory, then the system directories and PATH; -rpath ignored"));
        }
        if !o->rpath_link.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning, "-rpath-link has no PE equivalent; ignored"));
        }
        if !o->dynamic_linker.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "PE images load through the Windows loader; --dynamic-linker ignored"));
        }
        if !o->emulation.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "lld-link takes the machine from the target, not an emulation; --emulation ignored"));
        }
    }

    /// `-l foo` is foo.lib: MSVC names a static archive and an import
    /// library the same way, so static: and dynamic: change nothing and the
    /// search path picks. A path to a .lib, .obj or .res goes in as an
    /// input; a .def goes in as -def.
    priv static fn _user_lib(spec: string, argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) {
        var name = spec;
        var mode = "";
        var c    = LinkText::find(spec, ":", 0);
        if c < spec.size() {
            mode = LinkText::slice(spec, 0, c);
            name = LinkText::slice(spec, c + 1, spec.size());
        }
        if (!mode.empty()) && (mode != "static") && (mode != "dynamic") {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"-l {spec}: unknown kind {mode}; expected static or dynamic"));
            return;
        }
        if name.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, f"-l {spec}: no library name"));
            return;
        }
        if LinkText::ends_with(name, ".def") {
            argv.push_back(f"-def:{name}");
            return;
        }
        if LinkText::contains(name, "/") || LinkText::ends_with(name, ".lib")
        || LinkText::ends_with(name, ".obj") || LinkText::ends_with(name, ".o")
        || LinkText::ends_with(name, ".a") || LinkText::ends_with(name, ".res") {
            argv.push_back(name);
            return;
        }
        argv.push_back(f"{name}.lib");
    }

    /// libc++, the builtins when asked for, the CRT, oldnames (POSIX names
    /// like write -> _write), kernel32.
    priv static fn _default_libs(tc: ref!(Toolchain), o: *LinkerOptions, no_crt: bool,
                                 argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) {
        var cxx = vec::<string>();
        var crt = vec::<string>();

        if tc.has_manifest {
            if !tc.manifest.has_libcxx {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"the sysroot {tc.sysroot} has no libc++ (has_libcxx = false), and Kairo objects need it"));
            }
            cxx = tc.manifest.libcxx_link;
            if !no_crt { crt = tc.manifest.libc_link; }
        } else {
            var s = COFFArgs::_lib(tc, "libc++.lib");
            if !s.empty() {
                cxx.push_back(s);
            } else {
                var d = COFFArgs::_lib(tc, "c++.lib");
                if d.empty() {
                    msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                        f"no libc++ for {tc.triple}: neither libc++.lib nor c++.lib is in the library search path, and Kairo objects need it"));
                } else {
                    cxx.push_back(d);
                    msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                        "libc++ is only available as an import library (c++.lib): the output needs c++.dll beside it"));
                }
            }

            if !no_crt {
                if COFFArgs::_user_links_crt(o) {
                    argv.push_back("-nodefaultlib:libcmt.lib");
                    argv.push_back("-nodefaultlib:libvcruntime.lib");
                    argv.push_back("-nodefaultlib:libucrt.lib");
                } else {
                    crt.push_back("libcmt.lib");
                    crt.push_back("libvcruntime.lib");
                    crt.push_back("libucrt.lib");
                }
                crt.push_back("oldnames.lib");
            }
            crt.push_back("kernel32.lib");
        }

        for x: string in cxx { argv.push_back(x); }
        if (tc.rtlib == "compiler-rt") && (!tc.builtins.empty()) { argv.push_back(tc.builtins); }
        for x: string in crt { argv.push_back(x); }
    }

    priv static fn _lib(tc: ref!(Toolchain), name: string) -> string {
        if !tc.toolchain_lib.empty() {
            var p = LinkText::join(tc.toolchain_lib, name);
            if LinkFS::is_file(p) { return p; }
        }
        return tc.find_lib_file(name);
    }

    priv static fn _user_links_crt(o: *LinkerOptions) -> bool {
        for spec: string in o->link_libs {
            var n = spec;
            var c = LinkText::find(spec, ":", 0);
            if c < spec.size() { n = LinkText::slice(spec, c + 1, spec.size()); }
            if LinkText::starts_with(n, "msvcrt") || LinkText::starts_with(n, "libcmt")
            || LinkText::starts_with(n, "ucrt") || LinkText::starts_with(n, "libucrt")
            || LinkText::starts_with(n, "vcruntime") || LinkText::starts_with(n, "libvcruntime") {
                return true;
            }
        }
        return false;
    }
}