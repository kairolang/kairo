/// --- The Kairo Project ----------------- Linker/API/Flavor/MachO.k ------ ///
///
///   \brief LinkJob + Toolchain -> ld64.lld argv. Decides nothing the
///          Toolchain did not resolve and runs nothing.
///
///   Order is clang's Darwin linker order, so a line from here diffs cleanly
///   against `clang++ -fuse-ld=lld -###` for the same target:
///
///     options, -arch, -platform_version, -syslibroot, -o, -L, rpaths,
///     behavior, objects, user libs, -lc++ -lSystem, builtins
///
///   There is no crt. dyld enters the image through LC_MAIN at _main, so
///   there is nothing to bracket the inputs with and -e works on ordinary
///   dynamic executables.
///
///   Output shape:
///     default     -dynamic (PIE is lld's default and not spelled out)
///     --shared    -dynamic -dylib, plus -install_name @rpath/<file> unless
///                 the ld flags name one. ld64 defaults the install name to
///                 the output path, which bakes the build directory into
///                 every client of the dylib.
///     -fno-pie    -no_pie, x86_64 only: arm64 executables are always PIE
///     --static    rejected. lld does not implement -static, and libSystem
///                 ships only as a dylib.
///
///   ELF-only options with no Mach-O meaning (hash style, relro, -z now,
///   noexecstack, eh-frame-hdr, compressed debug sections) are dropped. The
///   ones whose silent drop would change the output are diagnosed.
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

class MachOArgs {
    static fn build(job: ref!(LinkJob), tc: ref!(Toolchain),
                    argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) -> bool {
        var errs0 = LinkDiag::error_count(msgs);
        var o     = job.opts;

        if job.output.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, "link: no output path"));
            return false;
        }
        if o->static_link || tc.static_only {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "static Mach-O executables are not supported: lld does not implement -static, and libSystem ships only as a dylib"));
            return false;
        }

        var shared  = o->shared;
        var no_libs = o->no_default_libs || o->freestanding;
        var arm     = LinkText::starts_with(tc.darwin_arch, "arm64");

        MachOArgs::_elf_only(o, msgs);

        // --- options -------------------------------------------------------
        argv.push_back("ld64.lld");
        argv.push_back("--color-diagnostics=never");
        argv.push_back("--error-limit=0");
        if job.threads > 0 { argv.push_back(f"--threads={job.threads}"); }
        argv.push_back("-demangle");
        argv.push_back("-dynamic");
        if shared { argv.push_back("-dylib"); }

        if (!shared) && (o->f_pie == 0) {
            if arm {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"-fno-pie: {tc.darwin_arch} Mach-O executables are always position independent"));
            } else {
                argv.push_back("-no_pie");
            }
        }

        argv.push_back("-arch");
        argv.push_back(tc.darwin_arch);
        argv.push_back("-platform_version");
        argv.push_back(tc.platform);
        argv.push_back(tc.min_version);
        argv.push_back(tc.sdk_version);
        argv.push_back("-syslibroot");
        argv.push_back(tc.sysroot);

        if shared && (!MachOArgs::_has_flag(o->ld_flags, "-install_name")) {
            argv.push_back("-install_name");
            argv.push_back(f"@rpath/{LinkFS::filename(job.output)}");
        }

        argv.push_back("-o");
        argv.push_back(job.output);

        // --- search path, user's first ---------------------------------------
        // The SDK's usr/lib comes from -syslibroot. A manifest sysroot may list
        // others, which lld would not find on its own.
        for d: string in o->lib_dirs { argv.push_back(f"-L{d}"); }
        if !tc.toolchain_lib.empty() { argv.push_back(f"-L{tc.toolchain_lib}"); }
        if tc.has_manifest {
            for d: string in tc.lib_dirs { argv.push_back(f"-L{d}"); }
        }

        for r: string in o->rpath { argv.push_back("-rpath"); argv.push_back(r); }
        if (!no_libs) && (!tc.toolchain_lib.empty()) {
            argv.push_back("-rpath");
            argv.push_back(tc.toolchain_lib);
            msgs.push_back(LinkDiag::make(LinkSeverity::Verbose,
                f"added -rpath {tc.toolchain_lib}: libc++ is linked from outside the SDK"));
        }

        // --- behavior -------------------------------------------------------
        if o->export_dynamic { argv.push_back("-export_dynamic"); }
        if o->f_gc_sections == 1 { argv.push_back("-dead_strip"); }
        if o->icf {
            if (o->icf_mode != "safe") && (o->icf_mode != "all") {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"unknown --icf-mode {o->icf_mode}; expected safe or all"));
            } else {
                argv.push_back(f"--icf={o->icf_mode}");
            }
        }
        // The global symbol table of a linked image cannot go: dyld binds
        // through it. -x drops the locals, -S the debug map.
        if o->strip            { argv.push_back("-S"); argv.push_back("-x"); }
        else if o->strip_debug { argv.push_back("-S"); }
        if !o->map_file.empty() { argv.push_back("-map"); argv.push_back(o->map_file); }
        if o->build_id == "none" { argv.push_back("-no_uuid"); }

        // --entry names a source-level symbol. Mach-O C symbols carry a
        // leading underscore, so main is _main.
        if (!shared) && (!o->no_entry) && (!o->entry.empty()) {
            argv.push_back("-e");
            argv.push_back("_" + o->entry);
        }
        for f: string in o->ld_flags { argv.push_back(f); }

        // --- inputs ----------------------------------------------------------
        for obj: string in job.objects { argv.push_back(obj); }
        for spec: string in o->link_libs { MachOArgs::_user_lib(spec, o, tc, argv, msgs); }

        if !no_libs { MachOArgs::_default_libs(tc, argv, msgs); }

        return LinkDiag::error_count(msgs) == errs0;
    }

    /// Options that mean something on ELF and nothing here. Diagnosed only
    /// where dropping them silently changes the output.
    priv static fn _elf_only(o: *LinkerOptions, msgs: ref!(vec::<LinkMessage>)) {
        if !o->linker_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "Mach-O has no linker scripts; lay out sections with -sectcreate, -segaddr or -order_file through ld flags"));
        }
        if !o->version_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "version scripts are ELF-only; control exports with -exported_symbols_list <file> through ld flags"));
        }
        if !o->rpath_link.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "-rpath-link has no Mach-O equivalent; ignored"));
        }
        if !o->emulation.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "--emulation is ELF-only; ignored"));
        }
        if !o->dynamic_linker.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "Mach-O executables always load through /usr/lib/dyld; --dynamic-linker ignored"));
        }
    }

    /// `-l foo`, `-l static:foo`, `-l dynamic:foo`, `-l weak:foo`,
    /// `-l framework:Foo`, or a path to an archive, object, dylib or .tbd,
    /// which goes in as an input.
    priv static fn _user_lib(spec: string, o: *LinkerOptions, tc: ref!(Toolchain),
                             argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) {
        var name = spec;
        var mode = "";
        var c    = LinkText::find(spec, ":", 0);
        if c < spec.size() {
            mode = LinkText::slice(spec, 0, c);
            name = LinkText::slice(spec, c + 1, spec.size());
        }
        if name.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, f"-l {spec}: no library name"));
            return;
        }

        if mode == "framework" {
            argv.push_back("-framework");
            argv.push_back(name);
            return;
        }

        if LinkText::contains(name, "/") || LinkText::ends_with(name, ".a")
        || LinkText::ends_with(name, ".o") || LinkText::ends_with(name, ".dylib")
        || LinkText::ends_with(name, ".tbd") {
            argv.push_back(name);
            return;
        }

        if mode == "static" {
            // No -Bstatic: ld64 takes the first of libfoo.dylib / libfoo.tbd /
            // libfoo.a in each directory, so a static request is a path.
            var a = MachOArgs::_find_archive(name, o, tc);
            if a.empty() {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"-l static:{name}: no lib{name}.a in the library search path"));
                return;
            }
            argv.push_back(a);
            return;
        }
        if mode == "weak" { argv.push_back(f"-weak-l{name}"); return; }
        if (!mode.empty()) && (mode != "dynamic") {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"-l {spec}: unknown kind {mode}; expected static, dynamic, weak or framework"));
            return;
        }
        argv.push_back(f"-l{name}");
    }

    priv static fn _find_archive(name: string, o: *LinkerOptions, tc: ref!(Toolchain)) -> string {
        var file = f"lib{name}.a";
        for d: string in o->lib_dirs {
            var p = LinkText::join(d, file);
            if LinkFS::is_file(p) { return p; }
        }
        if !tc.toolchain_lib.empty() {
            var p = LinkText::join(tc.toolchain_lib, file);
            if LinkFS::is_file(p) { return p; }
        }
        for d: string in tc.lib_dirs {
            var p = LinkText::join(d, file);
            if LinkFS::is_file(p) { return p; }
        }
        return "";
    }

    /// libc++ (Kairo objects always need it; the SDK's libc++.tbd re-exports
    /// libc++abi), libSystem (libc, libm, pthread, the unwinder, dyld's
    /// stub binder), then the builtins archive when one was found. Matches
    /// clang: -lc++ -lSystem <resource>/lib/darwin/libclang_rt.<os>.a
    priv static fn _default_libs(tc: ref!(Toolchain), argv: ref!(vec::<string>),
                                 msgs: ref!(vec::<LinkMessage>)) {
        var cxx  = vec::<string>();
        var libc = vec::<string>();
        if tc.has_manifest {
            if !tc.manifest.has_libcxx {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"the sysroot {tc.sysroot} has no libc++ (has_libcxx = false), and Kairo objects need it"));
            }
            cxx  = tc.manifest.libcxx_link;
            libc = tc.manifest.libc_link;
        }
        if cxx.empty()  { cxx.push_back("-lc++"); }
        if libc.empty() { libc.push_back("-lSystem"); }

        for x: string in cxx  { argv.push_back(x); }
        for x: string in libc { argv.push_back(x); }
        if !tc.builtins.empty() { argv.push_back(tc.builtins); }
    }

    priv static fn _has_flag(xs: ref!(vec::<string>), f: string) -> bool {
        for x: string in xs { if x == f { return true; } }
        return false;
    }
}