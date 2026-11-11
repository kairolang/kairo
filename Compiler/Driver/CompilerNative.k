/// --- The Kairo Project ---------------------- Driver/CompilerNative.k --- ///
///
///   CompilerInstance, part: native objects. What clang compiles beside
///   the Kairo TUs: the runtime (Lib/rt), started early on the pool during
///   Sema and joined before the link, and the C/C++/ObjC/IR inputs
///   through clang's in-process driver. An `extend` of the class in
///   CompilerInstance.k (Driver/module.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/ADT/StringExtras.h"
ffi "c++" import "clang/Frontend/FrontendActions.h"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"
ffi "c++" import "system_error"

import API::FS::LinkFS
import API::Text::LinkText
import Codegen::Backend::CodegenAction::EmitKind
import Command::FlagTranslator::{
    ClangSpelling,
    FlagTranslator,
}
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Driver::CompilerInstance::CompilerInstance
import Driver::InputKinds::{
    InputClass,
    InputKind,
    classify_input,
}
import Driver::KairoIncludes::DriverIncludeSource
import Interop::Clang::ClangBackend::{
    ClangBackend,
    NATIVE_GROUP,
}
import Interop::Clang::ClangJobs::ClangJobs
import Location::SourceManager::SourceManager
import Support::FileIO::FileSystem::FileType
import Support::FileIO::Path::Path
import std::env
import std::io

extend CompilerInstance {
    /// \brief the runtime's C/C++ sources (Lib/rt), when Kairo objects were
    ///        emitted, into <dir>/kairo/<stem>.o beside kairo/std.o.
    ///
    /// \details On the hand-built cc1 line (ClangBackend::native_invocation and run_native),
    ///          not clang's driver: the runtime is Kairo's own code and is
    ///          built exactly as Kairo's TUs are (int128, no finite loops,
    ///          Kairo's exception model). Runtime objects never take -o.
    ///
    ///          Each object is taken from the toolchain's runtime cache
    ///          (_rt_cache_dir) when an entry for its exact cc1 line and
    ///          inputs is there, and stored into it after a compile: without
    ///          it every link rebuilt mimalloc at -O2, 1.6 s of a 2 s
    ///          trivial program. Copied in and out rather than linked from
    ///          the cache, so a link never holds a file another run may
    ///          replace or collect, and --kairo-lib's private build
    ///          directory still holds its own objects.
    /// \brief compiles the runtime's C sources (Lib/rt) to objects, for the
    ///        link: _start_runtime unless it already ran, then _finish_runtime.
    ///
    /// \details The runtime depends on no Kairo source, so the batch starts it
    ///          as soon as the first action reaches Sema (prestart_runtime),
    ///          on pool threads that the serial Sema leaves idle, instead of
    ///          after codegen, where a cache miss (every first link after a
    ///          compiler rebuild) put ~4 s of -O2 compiles on the critical
    ///          path. The objects, logs and cache stores are the same.
    prot fn _compile_runtime(self) -> bool {
        if !self._rt_started {
            if !self._start_runtime() {
                return false
            }
        }

        return self._finish_runtime()
    }

    /// The batch's early start (FrontendAction::_sema): only when this run
    /// will compile the runtime at all -- the same test as the batch's call.
    fn prestart_runtime(self) {
        if self._rt_started || self._rt_prestart_tried {
            return
        }

        self._rt_prestart_tried = true
        var *fe_rt = &self.invocation()->frontend
        if self._kairo_inputs == 0
            || fe_rt->stops_before_codegen()
            || !fe_rt->emit_obj
            || self.invocation()->linker.inputs_only()
            || self._link_out.empty() {
            return
        }

        if !self._start_runtime() {
            self._rt_started = false
        }
    }

    /// Joins an early start the batch then did not use (an error stopped it
    /// before the link): the tasks write into members, so they must finish.
    prot fn _join_runtime(self) {
        if !self._rt_started {
            return
        }

        self._pool->wait_group(NATIVE_GROUP)
    }

    priv fn _start_runtime(self) -> bool {
        self._rt_invs.clear()
        self._rt_objs.clear()
        self._rt_logs.clear()
        self._rt_oks.clear()
        self._rt_ents.clear()
        self._rt_cache   = ""
        self._rt_started = true
        var runtime = self._runtime_sources()
        if runtime.size() == 0 {
            return true
        }

        if self._backend == &null {
            self._rt_started = false
            self._diag->report(DiagID::I004F, "cannot compile the runtime: no clang backend").emit()
            return false
        }

        var dir = self.object_dir()
        var n   = runtime.size()
        // The vendored mimalloc's headers, for rt/mimalloc.c alone: rt/alloc.h
        // declares the mi_* entry points it calls itself, so neither Kairo
        // TUs nor the user's C/C++ see mimalloc's include/ (its mimalloc.h
        // would shadow a user's own copy).
        var extra = cxx::std::vector<string>()
        extra.push_back("-I")
        extra.push_back(Path::join_str(self._runtime_root(), "rt/mimalloc/include"))

        // Side by side on the pool: each file is its own CompilerInstance
        // (ClangBackend::run_native) printing into its own log. The
        // invocations are built here first, because their argv bytes and
        // the arg-parse engine are the backend's; the logs, objects and
        // verdict are read back in input order, so the output is the
        // serial loop's whatever finishes first.

        var cache = self._rt_cache_dir()
        if !cache.empty() && !LinkFS::make_dirs(cache) {
            cache = ""
        }

        self._rt_cache = cache
        var fp = ""
        if !cache.empty() {
            fp = kairo::std::from_std_string<string>(
                llvm::utohexstr(llvm::xxh3_64bits(kairo::sref(self._rt_fingerprint()))),
            )
        }

        var force = self.invocation()->frontend.force_recompile
        var exe   = env::exe_path()
        var none  = cxx::std::shared_ptr<clang::CompilerInvocation>()

        for *src in runtime {
            var stem = Path(src->path).stem()
            var obj  = dir + "/kairo/" + stem + ".o"
            Path::make_parent_dirs(obj)
            var key = ""
            var inv = self._backend->native_invocation(
                src->path,
                obj,
                src->type_name(),
                src->is_c_family_c(),
                extra,
                unsafe &key,
            )

            var entry = ""
            var hit   = false
            if !cache.empty() && inv.get() != &null {
                // <stem>-<slot>-<inputs>.o: the slot is the compiler and the
                // cc1 line, the second hash every file the object is built
                // from. A store replaces its slot's older entries, so a
                // compiler rebuild or a Lib/rt edit replaces the entry
                // rather than adding one per build.
                var slot = kairo::std::from_std_string<string>(
                    llvm::utohexstr(llvm::xxh3_64bits(kairo::sref(exe + "\n" + key))),
                )

                entry = cache + "/" + stem + "-" + slot + "-" + fp + ".o"
                if force {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"runtime cache bypassed (--force-recompile): {entry}",
                    )
                } else if CompilerInstance::_rt_cache_fetch(entry, obj) {
                    kairo::Logger::info(kairo::Logger::Stage::Driver, f"runtime cache hit: {entry}")
                    hit = true
                } else {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"runtime cache miss: {entry}",
                    )
                }
            }

            if hit {
                self._rt_invs.push_back(none)
                self._rt_ents.push_back("")
                self._rt_oks.push_back(1 as u8)
            } else {
                self._rt_invs.push_back(inv)
                self._rt_ents.push_back(entry)
                self._rt_oks.push_back(0 as u8)
            }

            self._rt_objs.push_back(obj)
            self._rt_logs.push_back("")
        }

        var unsafe *be    = self._backend
        var unsafe *inv_p = self._rt_invs.data()
        var unsafe *log_p = self._rt_logs.data()
        var unsafe *ok_p  = self._rt_oks.data()
        var unsafe *rec   = kairo::TimeReport::current()
        for var i: usize = 0; i < n; ++i {
            if inv_p[i].get() == &null {
                continue
            }

            self._pool->enqueue(
                kairo::SmallFunction<64>(
                    fn () |be, inv_p, log_p, ok_p, i, rec| {
                        var _kt = kairo::TimeReport::Worker(rec)
                        if be->run_native(inv_p[i], &log_p[i]) {
                            ok_p[i] = (1)
                        }
                    },
                ),
                NATIVE_GROUP,
            )
        }

        return true
    }

    priv fn _finish_runtime(self) -> bool {
        if !self._rt_started {
            return true
        }

        self._rt_started = false
        self._pool->wait_group(NATIVE_GROUP)
        var n      = self._rt_objs.size()
        var ok     = true
        var stored = false
        for var i: usize = 0; i < n; ++i {
            if !self._rt_logs[i].empty() {
                io::eprint(f"{self._rt_logs[i]}")
            }

            if self._rt_oks[i] == (0 as u8) {
                ok = false
                continue
            }

            if !self._rt_ents[i].empty() {
                stored = CompilerInstance::_rt_cache_store(self._rt_objs[i], self._rt_ents[i])
                    || stored
            }

            self._native_objs.push_back(self._rt_objs[i])
            kairo::Logger::info(kairo::Logger::Stage::Driver, f"emitted object {self._rt_objs[i]}")
        }

        if stored {
            CompilerInstance::_rt_cache_gc(self._rt_cache)
        }

        return ok
    }

    /// \brief the clang driver words for one C/C++ input, without the
    ///        action and the input/output: the backend's roots, everything
    ///        FlagTranslator::to_driver spells for this invocation (ending in
    ///        --cxx-flags, so those win), then the runtime root.
    priv fn _native_words(self, const k: InputKind) -> cxx::std::vector<string> {
        return self._native_words_for(self._backend, k)
    }

    /// _native_words against a given backend: --print-clang-args builds a
    /// throwaway one, the compile uses the build's.
    prot fn _native_words_for(self,
                              be: unsafe *ClangBackend,
                              k:  InputKind) -> cxx::std::vector<string> {
        var w = cxx::std::vector<string>()
        // IR and already-preprocessed input search no headers: the roots would
        // only draw clang's "argument unused" warning, once per root.
        if k.needs_headers() {
            w = be->sysroot_words(k.is_c_family_c(), ClangSpelling::Driver)
        }

        // Plugins that do not exist were reported when the backend's
        // configuration was built; here they are only left out.
        var missing = cxx::std::vector<string>()
        for var a: string in FlagTranslator::to_driver(&*self.invocation(), be->triple(), be->sysroot_clang_triple(), k.type_name(), unsafe &missing) {
            w.push_back(a)
        }

        // `rt/fmt.h` resolves for a C/C++ input exactly as for Lib/rt, and
        // the runtime root comes AFTER the user's -I, as on the cc1 line
        // (_backend_config): a quoted include that exists under both Lib
        // and a user -I dir names the user's file in both clang lines and
        // in the `#include "x.k"` scan (clang_include_dirs). -I is not
        // last-wins, so following --cxx-flags takes nothing from them.
        if k.needs_headers() {
            var rt_root = self._runtime_root()
            if !rt_root.empty() {
                w.push_back("-I")
                w.push_back(rt_root)
            }
        }

        return w
    }

    /// \brief the driver words a C++ input of this invocation compiles with
    ///        (_native_words for a `.cc`), for kals' clangd bridge: clangd
    ///        must parse a C++ file that includes a `.k` with kcc's roots
    ///        (the sysroot's libc++, the runtime root, the -std), or the
    ///        generated header's prelude meets another standard library
    ///        (libstdc++ declares `__make_unsigned`, which turns off clang's
    ///        builtin of that name that rt/intrinsics.h uses). Empty without
    ///        a backend.
    pub fn cxx_driver_words(self) -> cxx::std::vector<string> {
        if self._backend == &null {
            return cxx::std::vector<string>()
        }

        return self._native_words_for(self._backend, classify_input("input.cc", ""))
    }

    /// \brief cxx_driver_words for a C input (`.c`): the C set kcc compiles
    ///        a `.c` with (C roots, C `-std`), for a C source kals' bridge
    ///        lists because it reaches a `.k` through a header (P861); the
    ///        C++ set's `-std=c++..` is an error for C. Empty without a
    ///        backend.
    pub fn c_driver_words(self) -> cxx::std::vector<string> {
        if self._backend == &null {
            return cxx::std::vector<string>()
        }

        return self._native_words_for(self._backend, classify_input("input.c", ""))
    }

    priv fn _native_jobs(self) -> unsafe *ClangJobs {
        if self._jobs == &null {
            var exe = Path::join_str(Path::parent_of(env::exe_path()), "clang")
            self._jobs = kairo::std::create<ClangJobs>(self._backend, exe)
            self._kincludes = kairo::std::create<DriverIncludeSource>(
                self._sm,
                self._g_scope,
                if (self._pp != &null) => (self._pp->get_symbol_table()) else => &null,
                !self.invocation()->frontend.stops_at_parse() || self.kairo_feeds_includes(),
            )

            self._jobs->includes = self._kincludes
        }

        return self._jobs
    }

    /// One driver run for one input; a failure clang did not explain itself
    /// (an external tool, an empty plan) is reported here.
    priv fn _run_native(self, const k: InputKind, @inout words: cxx::std::vector<string>) -> bool {
        var unsafe *jobs = self._native_jobs()
        var        ok    = jobs->run(&words)
        jobs->diags.drain_into(
            unsafe (self._diag as unsafe *DiagEngine),
            unsafe (self._sm as unsafe *SourceManager),
        )

        if ok {
            return true
        }

        if !jobs->error.empty() {
            self._diag->report(DiagID::U011E, f"{k.path}: {jobs->error}").emit()
        }

        return false
    }

    /// \brief compiles the command line's C, C++, Objective-C and IR inputs
    ///        through clang's driver, for the run's action:
    ///
    ///          --preprocess       -E, to -o or stdout
    ///          --syntax-only,
    ///          --type-check-only  -fsyntax-only (C++ has no separate stage)
    ///          otherwise          each --emit kind: <dir>/<stem>.o .s .ll .bc
    ///                             (-c / -S / -S -emit-llvm / -c -emit-llvm);
    ///                             the .o files join the link.
    ///
    ///        -o names the output only when it is the build's one output.
    prot fn _compile_sources(self, @inout natives: cxx::std::vector<InputKind>) -> bool {
        if natives.size() == 0 {
            return true
        }

        if self._backend == &null {
            self._diag->report(
                DiagID::I004F,
                "cannot compile C/C++ sources: no clang backend",
            ).emit()
            return false
        }

        var *fe    = &self.invocation()->frontend
        var single = self.single_object()

        if fe->stops_at_preprocess() || fe->stops_at_sema() {
            var pp = fe->stops_at_preprocess()
            var ok = true
            for *k in natives {
                // An input with no such phase is skipped with a warning, as
                // clang does (-E: input unused): IR and .i/.ii for -E, IR for
                // -fsyntax-only.
                var skip = pp && !k->needs_headers() || !pp && k->is_ir()
                if skip {
                    var what = if (pp) => ("--preprocess") else => "a check-only run"
                    self._diag->report(
                        DiagID::U012W,
                        f"{k->path}: nothing to do for this input under {what}",
                    ).emit()
                    continue
                }

                var w = self._native_words(*k)
                w.push_back(if (pp) => ("-E") else => "-fsyntax-only")
                if pp && !single.empty() {
                    if natives.size() != 1 {
                        self._diag->report(
                            DiagID::I004F,
                            f"-o {single} names one output, but this build preprocesses {natives.size()} inputs",
                        ).emit()
                        return false
                    }

                    w.push_back("-o")
                    w.push_back(single)
                }

                w.push_back("-x")
                w.push_back(k->type_name())
                w.push_back(k->path)
                ok = self._run_native(*k, &w) && ok
            }

            return ok
        }

        // What each input writes (--emit), the same kinds and extensions a
        // Kairo TU writes, one driver run each.
        var kinds = cxx::std::vector<EmitKind>()
        var exts  = cxx::std::vector<string>()
        if fe->emit_obj {
            kinds.push_back(EmitKind::Obj)
            exts.push_back(".o")
        }

        if fe->emit_asm {
            kinds.push_back(EmitKind::Asm)
            exts.push_back(".s")
        }

        if fe->emit_llvm_ir {
            kinds.push_back(EmitKind::LLVMIR)
            exts.push_back(".ll")
        }

        if fe->emit_llvm_bc {
            kinds.push_back(EmitKind::LLVMBC)
            exts.push_back(".bc")
        }

        // A header writes one .pch whatever --emit says.
        var n_out = self.kairo_input_count() * kinds.size() + self._header_inputs
        if !single.empty() && n_out > 1 {
            self._diag->report(
                DiagID::I004F,
                f"-o {single} names one output, but this build emits {n_out}; use --cache-dir <dir> for them",
            ).emit()
            return false
        }

        var dir = self.object_dir()

        var ok = true
        for *k in natives {
            if k->cls == InputClass::Header {
                // clang's own answer to a header input: a precompiled header,
                // named after the whole file (foo.h -> foo.h.pch) so foo.h
                // and foo.c never collide. Never linked.
                var pch = single
                // A linking run's object dir may be a temporary one it
                // deletes; the .pch is an output the user asked for, so it is
                // kept: --cache-dir if given, else the working directory.
                var pdir = dir
                if self._obj_tmp {
                    pdir = "."
                }

                if pch.empty() {
                    pch = pdir + "/" + Path(k->path).filename() + ".pch"
                }

                Path::make_parent_dirs(pch)
                var hw = self._native_words(*k)
                hw.push_back("-c")
                hw.push_back("-x")
                hw.push_back(k->type_name())
                hw.push_back(k->path)
                hw.push_back("-o")
                hw.push_back(pch)
                ok = self._run_native(*k, &hw) && ok
                continue
            }

            for var i: usize = 0; i < kinds.size(); ++i {
                var out = single
                if out.empty() {
                    out = dir + "/" + Path(k->path).stem() + exts[i]
                }

                Path::make_parent_dirs(out)
                var w    = self._native_words(*k)
                var kind = kinds[i]
                if kind == EmitKind::Asm {
                    w.push_back("-S")
                } else if kind == EmitKind::LLVMIR {
                    w.push_back("-S")
                    w.push_back("-emit-llvm")
                } else if kind == EmitKind::LLVMBC {
                    w.push_back("-c")
                    w.push_back("-emit-llvm")
                } else {
                    w.push_back("-c")
                }

                w.push_back("-x")
                w.push_back(k->type_name())
                w.push_back(k->path)
                w.push_back("-o")
                w.push_back(out)
                var one = self._run_native(*k, &w)
                ok = one && ok
                if one && kind == EmitKind::Obj {
                    self._native_objs.push_back(out)
                    kairo::Logger::info(kairo::Logger::Stage::Driver, f"emitted object {out}")
                }
            }
        }

        return ok
    }

    /// \brief the directory the runtime is included and compiled from: the
    ///        builtin root's parent -- Lib/ in the tree, <resource-dir>
    ///        installed -- so `rt/fmt.h` names Lib/rt/fmt.h from anywhere. The
    ///        builtin root is found as the import resolver finds it:
    ///        --builtins-dir, else <resource-dir>/builtin. "" when none.
    prot fn _runtime_root(self) -> string {
        var broot = self.invocation()->pp.builtins_dir
        if broot.empty() && !self.invocation()->target.resource_dir.empty() {
            broot = (Path(self.invocation()->target.resource_dir) / "builtin").full_path()
        }

        if broot.empty() {
            return ""
        }

        // A trailing '/' would make parent_path answer "a/builtin" for
        // "a/builtin/"; strip it so both spellings name Lib/.
        return Path::parent_of(LinkText::strip_slash(broot))
    }

    /// \brief the runtime's C/C++ sources: every one directly in
    ///        <runtime root>/rt. No root, no runtime. Sorted, so object
    ///        order does not follow readdir.
    prot fn _runtime_sources(self) -> cxx::std::vector<InputKind> {
        var out   = cxx::std::vector<InputKind>()
        var rroot = self._runtime_root()
        if rroot.empty() {
            return out
        }

        var root                      = Path::join_str(rroot, "rt")
        var ec:  cxx::std::error_code
        var it  = llvm::sys::fs::directory_iterator(llvm::Twine(kairo::sref(root)), &ec, true)
        var end = llvm::sys::fs::directory_iterator()

        for ; ec.value() == 0 && it != end; it.increment(&ec) {
            if Path::type_of_entry(*it) != FileType::regular_file {
                continue
            }

            var p = it->path()
            // The same classifier as a command-line input: rt holds C and
            // C++ only, and a stray header or README must not compile.
            var k = classify_input(
                string(unsafe ((p.data() as unsafe *const u8) as *const u8), p.size()),
                "",
            )

            if k.cls == InputClass::Source {
                out.push_back(k)
            }
        }

        llvm::sort(
            out.begin(),
            out.end(),
            fn (const a: InputKind, const b: InputKind) || -> bool = a.path < b.path,
        )

        return out
    }

    /// \brief every file the runtime's sources include from the vendored
    ///        mimalloc (<runtime root>/rt/mimalloc/{src,include}, recursive),
    ///        for the library manifest.
    ///
    /// \details rt/mimalloc.c is one line of #include into the submodule:
    ///          a submodule bump changes these and never mimalloc.c, so a
    ///          manifest of _runtime_sources() alone would keep a cached
    ///          runtime object built from the old mimalloc. Sorted, so the
    ///          manifest does not follow readdir.
    prot fn _runtime_deps(self) -> cxx::std::vector<string> {
        var out   = cxx::std::vector<string>()
        var rroot = self._runtime_root()
        if rroot.empty() {
            return out
        }

        var subs = cxx::std::vector<string>()
        subs.push_back("rt/mimalloc/src")
        subs.push_back("rt/mimalloc/include")
        for *sub in subs {
            var root                      = Path::join_str(rroot, (*sub))
            var ec:  cxx::std::error_code
            var it = llvm::sys::fs::recursive_directory_iterator(
                llvm::Twine(kairo::sref(root)),
                &ec,
                true,
            )

            var end = llvm::sys::fs::recursive_directory_iterator()
            for ; ec.value() == 0 && it != end; it.increment(&ec) {
                if Path::type_of_entry(*it) != FileType::regular_file {
                    continue
                }

                var p = it->path()
                out.push_back(
                    string(unsafe ((p.data() as unsafe *const u8) as *const u8), p.size()),
                )
            }
        }

        llvm::sort(out.begin(), out.end(), fn (const a: string, const b: string) || -> bool = a < b)
        return out
    }

    priv static fn _parent_dir(const path: string) -> string {
        return Path::parent_of(path)
    }
}
