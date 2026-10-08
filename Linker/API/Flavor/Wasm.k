/// --- The Kairo Project ------------------ Linker/API/Flavor/Wasm.k ------ ///
///
///   \brief LinkJob + Toolchain -> wasm-ld argv for wasm32/wasm64 targets:
///          WASI preview 1 (wasm32-wasip1, wasm32-wasi) and bare
///          (wasm32-unknown-unknown). Decides nothing the Toolchain did not
///          resolve and runs nothing.
///
///   Order is clang's WebAssembly linker order, so a line from here lines
///   up against `clang++ --target=wasm32-wasip1 --sysroot=<s> -###`:
///
///     options, -o, crt1, -L, behavior, objects, user libs, default libs
///
///   Output shape:
///     wasi        a command module: crt1-command.o (crt1.o on older
///                 wasi-libc) supplies _start, which calls main
///     bare        a library module: no crt, --no-entry unless --entry
///                 names one; exports go through ld flags (--export=...)
///     --shared    rejected. wasm dynamic linking is emscripten's ABI.
///     --static    nothing to do: every module is static
///
///   A bare target has no libc, so no libc++, so no Kairo runtime: it links
///   only freestanding.
///
///   Exceptions: wasi-sdk's libc++ is built without them. A sysroot whose
///   libc++ uses wasm EH (-fwasm-exceptions) needs --unwindlib=libunwind,
///   or a manifest whose libcxx_link names it.
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

class WasmArgs {
    static fn build(job: ref!(LinkJob), tc: ref!(Toolchain),
                    argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) -> bool {
        var errs0 = LinkDiag::error_count(msgs);
        var o     = job.opts;

        if job.output.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, "link: no output path"));
            return false;
        }
        if o->shared {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "shared wasm modules are emscripten's dynamic-linking ABI and are not supported; link a static module"));
            return false;
        }

        var bare    = tc.libc.empty();
        var no_libs = o->no_default_libs || o->freestanding;
        var no_crt  = o->no_crt || o->no_entry || o->freestanding || bare;

        if bare && (!no_libs) {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"{tc.triple} has no libc, and Kairo's runtime needs libc++; target wasm32-wasip1, or pass --freestanding"));
            return false;
        }

        WasmArgs::_ignored(o, msgs);

        // --- options -------------------------------------------------------
        argv.push_back("wasm-ld");
        argv.push_back("-m");
        argv.push_back(tc.emulation);
        argv.push_back("--color-diagnostics=never");
        argv.push_back("--error-limit=0");
        if job.threads > 0 { argv.push_back(f"--threads={job.threads}"); }
        // wasm-ld writes no build id unless asked, so "none" is the default.
        if (!o->build_id.empty()) && (o->build_id != "none") { argv.push_back(f"--build-id={o->build_id}"); }

        argv.push_back("-o");
        argv.push_back(job.output);

        // --- crt startup ---------------------------------------------------
        if !no_crt {
            if tc.has_manifest && (!tc.manifest.crt_startup.empty()) {
                for n: string in tc.manifest.crt_startup { WasmArgs::_crt(tc, n, argv, msgs); }
            } else {
                var c = tc.find_lib_file("crt1-command.o");
                if c.empty() { WasmArgs::_crt(tc, "crt1.o", argv, msgs); }
                else         { argv.push_back(c); }
            }
        }

        // --- search path, user's first ----------------------------------------
        for d: string in o->lib_dirs { argv.push_back(f"-L{d}"); }
        if !tc.toolchain_lib.empty() { argv.push_back(f"-L{tc.toolchain_lib}"); }
        for d: string in tc.lib_dirs { argv.push_back(f"-L{d}"); }

        // --- behavior -------------------------------------------------------
        if o->export_dynamic { argv.push_back("--export-dynamic"); }
        if o->f_gc_sections == 1 { argv.push_back("--gc-sections");    }
        if o->f_gc_sections == 0 { argv.push_back("--no-gc-sections"); }
        if o->strip            { argv.push_back("--strip-all");   }
        else if o->strip_debug { argv.push_back("--strip-debug"); }
        if !o->map_file.empty() { argv.push_back(f"--Map={o->map_file}"); }

        // With crt, _start is the entry. Without it the module has none unless
        // one is named.
        if o->no_entry || (no_crt && o->entry.empty()) {
            argv.push_back("--no-entry");
        } else if no_crt {
            argv.push_back(f"--entry={o->entry}");
        }
        for f: string in o->ld_flags { argv.push_back(f); }

        // --- inputs ----------------------------------------------------------
        for obj: string in job.objects { argv.push_back(obj); }
        for spec: string in o->link_libs { WasmArgs::_user_lib(spec, argv, msgs); }

        if !no_libs { WasmArgs::_default_libs(tc, argv, msgs); }

        // --- crt end ---------------------------------------------------------
        if (!no_crt) && tc.has_manifest {
            for n: string in tc.manifest.crt_end { WasmArgs::_crt(tc, n, argv, msgs); }
        }

        return LinkDiag::error_count(msgs) == errs0;
    }

    priv static fn _ignored(o: *LinkerOptions, msgs: ref!(vec::<LinkMessage>)) {
        if !o->linker_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "wasm-ld takes no linker scripts; set memory layout with --global-base, --stack-first and -z stack-size through ld flags"));
        }
        if !o->version_script.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                "version scripts are ELF-only; control exports with --export=<sym> or --export-if-defined=<sym> through ld flags"));
        }
        if o->icf {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, "wasm-ld does not implement identical code folding"));
        }
        if (!o->rpath.empty()) || (!o->rpath_link.empty()) {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning, "wasm modules have no library search at load time; -rpath ignored"));
        }
        if !o->dynamic_linker.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Warning,
                "wasm modules load through the host runtime; --dynamic-linker ignored"));
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

    /// `-l foo`, `-l static:foo`, or a path to an archive or object, which
    /// goes in as an input. `dynamic:` cannot be satisfied: wasm links
    /// statically.
    priv static fn _user_lib(spec: string, argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) {
        var name = spec;
        if LinkText::starts_with(spec, "static:") {
            name = LinkText::slice(spec, 7, spec.size());
        } else if LinkText::starts_with(spec, "dynamic:") {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                f"-l {spec}: wasm modules link statically; there is no dynamic library to bind"));
            return;
        }
        if name.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, f"-l {spec}: no library name"));
            return;
        }
        if LinkText::contains(name, "/") || LinkText::ends_with(name, ".a")
        || LinkText::ends_with(name, ".o") {
            argv.push_back(name);
            return;
        }
        argv.push_back(f"-l{name}");
    }

    /// clang's order: -lc++ -lc++abi [-lunwind] -lc <builtins>.
    priv static fn _default_libs(tc: ref!(Toolchain), argv: ref!(vec::<string>),
                                 msgs: ref!(vec::<LinkMessage>)) {
        if tc.has_manifest {
            if !tc.manifest.has_libcxx {
                msgs.push_back(LinkDiag::make(LinkSeverity::Error,
                    f"the sysroot {tc.sysroot} has no libc++ (has_libcxx = false), and Kairo objects need it"));
            }
            for x: string in tc.manifest.libcxx_link { argv.push_back(x); }
            for x: string in tc.manifest.libc_link   { argv.push_back(x); }
        } else {
            argv.push_back("-lc++");
            argv.push_back("-lc++abi");
            if tc.unwindlib == "libunwind" { argv.push_back("-lunwind"); }
            argv.push_back("-lc");
        }
        if !tc.builtins.empty() { argv.push_back(tc.builtins); }
    }
}