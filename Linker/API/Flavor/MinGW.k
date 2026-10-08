/// --- The Kairo Project ----------------- Linker/API/Flavor/MinGW.k ------ ///
///
///   \brief LinkJob + Toolchain -> ld.lld argv for MinGW-w64 targets
///          (<arch>-windows-gnu). MSVC targets go through COFF.k.
///          Decides nothing the Toolchain did not resolve and runs nothing.
///
///   argv[0] stays ld.lld. lld's dispatcher hands a GNU-flavor link whose
///   -m names a PE emulation (i386pep, i386pe, arm64pe, thumb2pe) to its
///   MinGW driver, which translates GNU options into lld-link's. The
///   runner, kld's -flavor gnu and posix response-file quoting carry over
///   unchanged: the dispatcher expands response files before it looks for
///   -m.
///
///   Order follows clang's MinGW linker order, so a line from here lines up
///   against `clang++ --target=x86_64-w64-mingw32 -fuse-ld=lld -###`:
///
///     options, -o, crt2/dllcrt2, crtbegin, -L, behavior, objects,
///     user libs, default libs, crtend
///
///   Output shape:
///     default     -Bdynamic, crt2.o; the entry is crt2's mainCRTStartup
///     --shared    --shared, dllcrt2.o, -e DllMainCRTStartup
///                 (_DllMainCRTStartup@12 on i386), --enable-auto-image-base
///     --static    -Bstatic: every -l prefers lib<x>.a to lib<x>.dll.a.
///                 System DLLs still load; their lib<x>.a are import libs.
///
///   The C++ runtime (libc++ and the unwinder) is bracketed -Bstatic in
///   every image, as Rust and Zig do on windows-gnu. Linked dynamically,
///   the exe needs libc++.dll and libunwind.dll beside it on the target
///   machine, and nothing on Windows puts them there. The CRT and the Win32
///   libraries stay dynamic: they ship with the OS.
///
///   lld's COFF backend resolves lazily across every archive on the line,
///   so there is no --start-group and nothing is repeated.
///
///   No PE meaning, dropped: hash style, relro, -z now, noexecstack,
///   eh-frame-hdr, compressed debug sections, PIE (lld marks every image
///   --dynamicbase). The ones whose silent drop would change the output
///   are diagnosed.
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
import Linker::API::LinkDiag::*;
import Linker::API::LinkJob::*;
import Linker::API::Toolchain::*;

class MinGWArgs {
    static fn build(job: ref!(LinkJob), tc: ref!(Toolchain),
                    argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) -> bool {
        var errs0 = LinkDiag::error_count(msgs);
        var o     = job.opts;

        if job.output.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, "link: no output path"));
            return false;
        }
        if tc.emulation.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"no PE emulation for {tc.arch}; pass --emulation"));
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

        var shared    = o->shared;
        var want_stat = o->static_link || tc.static_only;
        var no_crt    = o->no_crt || o->no_entry || o->freestanding;
        var no_libs   = o->no_default_libs || o->freestanding;

        MinGWArgs::_elf_only(o, msgs);

        // --- options -------------------------------------------------------
        // No --color-diagnostics: the MinGW driver has no such option, and
        // neither capture path is a tty, so lld never colors here anyway.
        argv.push_back("ld.lld");
        argv.push_back("-m");
        argv.push_back(tc.emulation);
        argv.push_back("--error-limit=0");
        if job.threads > 0 { argv.push_back(f"--threads={job.threads}"); }

        if shared { argv.push_back("--shared"); }
        argv.push_back(("-Bstatic") if (want_stat) else ("-Bdynamic"));

        if shared {
            if o->no_entry {
                // The MinGW driver has no --no-entry; -Xlink passes lld-link's
                // /noentry through.
                argv.push_back("-Xlink=-noentry");
            } else {
                argv.push_back("-e");
                argv.push_back(("_DllMainCRTStartup@12") if (tc.arch == "i386") else ("DllMainCRTStartup"));
            }
            argv.push_back("--enable-auto-image-base");
        }

        if o->build_id == "none"      { argv.push_back("--build-id=none"); }
        else if !o->build_id.empty()  { argv.push_back("--build-id"); }

        argv.push_back("-o");
        argv.push_back(job.output);

        // --- crt startup ---------------------------------------------------
        if !no_crt {
            if tc.has_manifest && (!tc.manifest.crt_startup.empty()) {
                for n: string in tc.manifest.crt_startup {
                    var name = n;
                    if shared && LinkText::starts_with(n, "crt1") { name = "dllcrt1.o"; }
                    if shared && LinkText::starts_with(n, "crt2") { name = "dllcrt2.o"; }
                    MinGWArgs::_crt(tc, name, argv, msgs);
                }
            } else {
                MinGWArgs::_crt(tc, ("dllcrt2.o") if (shared) else ("crt2.o"), argv, msgs);
                var cb = tc.crt_object("crtbegin", "");
                if !cb.empty() { argv.push_back(cb); }
            }
        }

        // --- search path, user's first ----------------------------------------
        for d: string in o->lib_dirs { argv.push_back(f"-L{d}"); }
        if !tc.toolchain_lib.empty() { argv.push_back(f"-L{tc.toolchain_lib}"); }
        if !tc.gcc_dir.empty()       { argv.push_back(f"-L{tc.gcc_dir}"); }
        for d: string in tc.lib_dirs { argv.push_back(f"-L{d}"); }

        // --- behavior -------------------------------------------------------
        // A PE image exports nothing unless asked. --export-dynamic means
        // "plugins can bind to me", which on PE is exporting everything.
        if o->export_dynamic { argv.push_back("--export-all-symbols"); }
        if o->f_gc_sections == 1 { argv.push_back("--gc-sections");    }
        if o->f_gc_sections == 0 { argv.push_back("--no-gc-sections"); }
        if o->icf {
            if (o->icf_mode != "safe") && (o->icf_mode != "all") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"unknown --icf-mode {o->icf_mode}; expected safe or all"));
            } else {
                argv.push_back(f"--icf={o->icf_mode}");
            }
        }
        if o->strip            { argv.push_back("--strip-all");   }
        else if o->strip_debug { argv.push_back("--strip-debug"); }
        if !o->map_file.empty() { argv.push_back(f"--Map={o->map_file}"); }

        // With crt, crt2's mainCRTStartup is the entry and calls main. The
        // MinGW driver strips i386's leading underscore itself, so the name
        // goes in undecorated.
        if no_crt && (!shared) && (!o->entry.empty()) {
            argv.push_back("-e");
            argv.push_back(o->entry);
        }
        for f: string in o->ld_flags { argv.push_back(f); }

        // --- inputs ----------------------------------------------------------
        for obj: string in job.objects { argv.push_back(obj); }
        for spec: string in o->link_libs { MinGWArgs::_user_lib(spec, want_stat, argv, msgs); }

        if !no_libs { MinGWArgs::_default_libs(tc, o, want_stat, argv, msgs); }

        // --- crt end ---------------------------------------------------------
        if !no_crt {
            if tc.has_manifest && (!tc.manifest.crt_end.empty()) {
                for n: string in tc.manifest.crt_end { MinGWArgs::_crt(tc, n, argv, msgs); }
            } else {
                var ce = tc.crt_object("crtend", "");
                if !ce.empty() { argv.push_back(ce); }
            }
        }

        return LinkDiag::error_count(msgs) == errs0;
    }

    /// Options that mean something on ELF and nothing here. Diagnosed only
    /// where dropping them silently changes the output.
    priv static fn _elf_only(o: *LinkerOptions, msgs: ref!(vec::<LinkMessage>)) {
        if !o->linker_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "PE has no linker scripts; place sections with --section-alignment, --image-base or an order file through ld flags"));
        }
        if !o->version_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "version scripts are ELF-only; control DLL exports with a .def file passed as an input"));
        }
        if !o->rpath.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "Windows has no rpath: DLLs load from the executable's directory, then the system directories and PATH; -rpath ignored"));
        }
        if !o->rpath_link.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "-rpath-link has no PE equivalent; ignored"));
        }
        if !o->dynamic_linker.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "PE images load through the Windows loader; --dynamic-linker ignored"));
        }
    }

    priv static fn _crt(tc: ref!(Toolchain), name: string,
                        argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) {
        var p = tc.find_lib_file(name);
        if p.empty() {
            var _where = (tc.crt_dir) if (!tc.crt_dir.empty()) else (tc.sysroot);
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"cannot find startup object {name} (searched {_where} and the sysroot library directories)"));
            return;
        }
        argv.push_back(p);
    }

    /// `-l foo`, `-l static:foo`, `-l dynamic:foo`, or a path to an archive,
    /// import library, object, DLL or .def, which goes in as an input.
    /// Unlike ELF, `dynamic:` survives a static link: -Bstatic only changes
    /// which file a -l prefers, and system DLLs load either way.
    priv static fn _user_lib(spec: string, want_stat: bool,
                             argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) {
        var name = spec;
        var mode = "";
        if LinkText::starts_with(spec, "static:") {
            mode = "static";
            name = LinkText::slice(spec, 7, spec.size());
        } else if LinkText::starts_with(spec, "dynamic:") {
            mode = "dynamic";
            name = LinkText::slice(spec, 8, spec.size());
        }
        if name.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, f"-l {spec}: no library name"));
            return;
        }
        if LinkText::contains(name, "/") || LinkText::ends_with(name, ".a")
        || LinkText::ends_with(name, ".o") || LinkText::ends_with(name, ".obj")
        || LinkText::ends_with(name, ".lib") || LinkText::ends_with(name, ".dll")
        || LinkText::ends_with(name, ".def") {
            argv.push_back(name);
            return;
        }
        if (mode == "static") && (!want_stat) {
            argv.push_back("-Bstatic");
            argv.push_back(f"-l{name}");
            argv.push_back("-Bdynamic");
            return;
        }
        if (mode == "dynamic") && want_stat {
            argv.push_back("-Bdynamic");
            argv.push_back(f"-l{name}");
            argv.push_back("-Bstatic");
            return;
        }
        argv.push_back(f"-l{name}");
    }

    /// libc++ and the unwinder (static, see the header), the builtins, then
    /// the MinGW CRT and the Win32 core:
    ///   -Bstatic -lc++ -lunwind -Bdynamic <builtins>
    ///   -lmingw32 -lmoldname -lmingwex -lmsvcrt
    ///   -ladvapi32 -lshell32 -luser32 -lkernel32
    /// As clang does, -lmsvcrt is dropped when the user links a CRT
    /// themselves (-l ucrt, -l msvcr120, ...): two CRTs in one image is two
    /// heaps and two sets of stdio.
    priv static fn _default_libs(tc: ref!(Toolchain), o: *LinkerOptions, want_stat: bool,
                                 argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) {
        var cxx  = vec::<string>();
        var libc = vec::<string>();
        if tc.has_manifest {
            if !tc.manifest.has_libcxx {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"the sysroot {tc.sysroot} has no libc++ (has_libcxx = false), and Kairo objects need it"));
            }
            cxx  = tc.manifest.libcxx_link;
            libc = tc.manifest.libc_link;
        } else {
            cxx.push_back("-lc++");
            if tc.unwindlib == "libunwind"   { cxx.push_back("-lunwind"); }
            else if tc.unwindlib == "libgcc" { cxx.push_back("-lgcc_eh"); }
            libc.push_back("-lmingw32");
            libc.push_back("-lmoldname");
            libc.push_back("-lmingwex");
            libc.push_back("-lmsvcrt");
            libc.push_back("-ladvapi32");
            libc.push_back("-lshell32");
            libc.push_back("-luser32");
            libc.push_back("-lkernel32");
        }

        if !want_stat { argv.push_back("-Bstatic"); }
        for x: string in cxx { argv.push_back(x); }
        if !want_stat { argv.push_back("-Bdynamic"); }

        if tc.rtlib == "compiler-rt" {
            if !tc.builtins.empty() { argv.push_back(tc.builtins); }
        } else {
            argv.push_back("-lgcc");
        }

        var user_crt = MinGWArgs::_user_links_crt(o);
        for x: string in libc {
            if user_crt && LinkText::starts_with(x, "-l")
            && MinGWArgs::_is_crt(LinkText::slice(x, 2, x.size())) { continue; }
            argv.push_back(x);
        }
    }

    priv static fn _user_links_crt(o: *LinkerOptions) -> bool {
        for spec: string in o->link_libs {
            var n = spec;
            var c = LinkText::find(spec, ":", 0);
            if c < spec.size() { n = LinkText::slice(spec, c + 1, spec.size()); }
            if MinGWArgs::_is_crt(n) { return true; }
        }
        return false;
    }

    priv static fn _is_crt(name: string) -> bool {
        return LinkText::starts_with(name, "msvcr") || LinkText::starts_with(name, "ucrt")
            || LinkText::starts_with(name, "crtdll");
    }
}