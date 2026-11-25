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
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Log.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"
ffi "c++" import "system_error"

import API::FS::LinkFS
import API::Text::LinkText
import Codegen::Backend::CodegenAction::{
    EmitKind,
    sema_agree_reports,
}
import Codegen::Backend::SemaAgreeReport::agree_emit
import Command::FlagTranslator::{
    ClangSpelling,
    FlagTranslator,
}
import Config::ResourceLayout::ResourceLayout
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Driver::CompilerCache
import Driver::CompilerInstance::CompilerInstance
import Driver::CompilerLink
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
import Native::TimeReport::TimeReport
import Support::Ascii::copy_strings
import Support::FileIO::FileSystem::FileType
import Support::FileIO::Path::Path
import std::env
import std::io

/// Orders by path.
fn input_kind_before(a: *const InputKind, b: *const InputKind) -> Ordering {
    return a->path <=> b->path
}

extend CompilerInstance {
    /// the runtime's C/C++ sources (Lib/rt), when Kairo objects were
    /// emitted, into <dir>/kairo/<stem>.o beside kairo/std.o.
    ///
    /// On the hand-built cc1 line (ClangBackend::native_invocation and run_native),
    /// not clang's driver: the runtime is Kairo's own code and is
    /// built exactly as Kairo's TUs are (int128, no finite loops,
    /// Kairo's exception model). Runtime objects never take -o.
    ///
    ///          Each object is taken from the toolchain's runtime cache
    ///          (_rt_cache_dir) when an entry for its exact cc1 line and
    ///          inputs is there, and stored into it after a compile: without
    ///          it every link rebuilt mimalloc at -O2, 1.6 s of a 2 s
    ///          trivial program. Copied in and out rather than linked from
    ///          the cache, so a link never holds a file another run may
    ///          replace or collect, and --kairo-lib's private build
    ///          directory still holds its own objects.
    ///
    /// compiles the runtime's C sources (Lib/rt) to objects, for the
    /// link: _start_runtime unless it already ran, then _finish_runtime.
    ///
    /// The runtime depends on no Kairo source, so the batch starts it
    /// as soon as the first action reaches Sema (prestart_runtime),
    /// on pool threads that the serial Sema leaves idle, instead of
    /// after codegen, where a cache miss (every first link after a
    /// compiler rebuild) put ~4 s of -O2 compiles on the critical
    /// path. The objects, logs and cache stores are the same.
    prot fn _compile_runtime(self) -> bool {
        if !self._rt_started {
            if !self._start_runtime() {
                return false
            }
        }

        return self._finish_runtime()
    }

    /// Compiles the runtime and keeps its heap object alone for the link: on
    /// ELF and wasm mimalloc's definitions of malloc, free and operator new
    /// replace the C library's (on MinGW operator new and delete only). The
    /// rest of the runtime serves Kairo code, which this link has none of;
    /// the heap object depends on nothing else in it. Linked eagerly, so its
    /// definitions win even when no object of the program references malloc
    /// before the C library is searched.
    prot fn _link_heap_only(self) -> bool {
        var before = self._native_objs.size()
        if !self._compile_runtime() {
            return false
        }

        var heap: [string]
        for var i: usize = before; i < self._native_objs.size(); ++i {
            if Path::stem_of(self._native_objs[i]) == ResourceLayout::rt_heap_stem() {
                heap.push(self._native_objs[i].copy())
            }
        }

        while self._native_objs.size() > before {
            self._native_objs.pop()
        }

        for *o in heap {
            self._native_objs.push(o->copy())
        }

        return true
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
            || self._link_out.is_empty() {
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
        self._rt_used.clear()
        self._rt_cache   = ""
        self._rt_started = true
        var runtime = self._runtime_sources()
        if runtime.size() == 0 {
            return true
        }

        if self._backend == &null {
            self._rt_started = false
            self._diag->report(
                DiagID::I004F,
                "cannot compile the runtime: no clang backend",
            ).emit()
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
        extra.push_back(
            Path::join_str(
                self._runtime_root(),
                ResourceLayout::mimalloc_include_subdir(),
            ),
        )

        // mimalloc's malloc_usable_size(void *) aliases
        // mi_malloc_usable_size(const void *), which clang 23 reports under
        // -Wattribute-alias. The runtime compiles on a cold cache inside the
        // user's compile, so the warning would reach their output. Clang 22
        // has no such group, hence the unknown-option silencer before it.
        extra.push_back("-Wno-unknown-warning-option")
        extra.push_back("-Wno-attribute-alias")

        // --heaplib=libc: Kairo allocations still go to mimalloc (System
        // calls its mi_* entry points), but malloc and operator new stay the
        // C and C++ libraries'. On every runtime source's line, not only the
        // heap's: one line keeps the cache slots of a run in step.
        if self.invocation()->linker.heaplib == "libc" {
            extra.push_back("-D" + ResourceLayout::rt_libc_heap_macro())
        }

        // Side by side on the pool: each file is its own CompilerInstance
        // (ClangBackend::run_native) printing into its own log. The
        // invocations are built here first, because their argv bytes and
        // the arg-parse engine are the backend's; the logs, objects and
        // verdict are read back in input order, so the output is the
        // serial loop's whatever finishes first.

        var cache = self._rt_cache_dir()
        if !cache.is_empty() && !LinkFS::make_dirs(cache) {
            cache = ""
        }

        self._rt_cache = cache.copy()
        var fp = ""
        if !cache.is_empty() {
            fp = kairo::std::from_std_string<string>(
                llvm::utohexstr(
                    llvm::xxh3_64bits(kairo::sref(self._rt_fingerprint())),
                ),
            )
        }

        var force = self.invocation()->frontend.force_recompile
        var exe   = env::exe_path()
        var none  = cxx::std::shared_ptr<clang::CompilerInvocation>()

        for *src in runtime {
            var stem = Path(src->path).stem()
            var obj  = dir.copy() + "/kairo/" + stem + ".o"
            Path::make_parent_dirs(obj)
            var key = ""
            var inv = self._backend->native_invocation(
                src->path,
                obj,
                src->type_name(),
                src->is_c_family_c(),
                copy_strings(extra),
                unsafe &key,
            )

            var entry = ""
            var hit   = false
            if !cache.is_empty() && inv.get() != &null {
                // <stem>-<slot>-<inputs>.o: the slot is the compiler and the
                // cc1 line, the second hash every file the object is built
                // from. A store replaces its slot's older entries, so a
                // compiler rebuild or a Lib/rt edit replaces the entry
                // rather than adding one per build.
                var slot = kairo::std::from_std_string<string>(
                    llvm::utohexstr(
                        llvm::xxh3_64bits(kairo::sref(exe.copy() + "\n" + key)),
                    ),
                )

                entry = cache.copy() + "/" + stem + "-" + slot + "-" + fp + ".o"
                if force {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"runtime cache bypassed (--force-recompile): {entry}",
                    )
                } else if CompilerInstance::_rt_cache_fetch(entry, obj) {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"runtime cache hit: {entry}",
                    )

                    self._rt_used.push(entry.copy())
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
                self._rt_ents.push("")
                self._rt_oks.push(1 as u8)
            } else {
                self._rt_invs.push_back(inv)
                self._rt_ents.push(entry)
                self._rt_oks.push(0 as u8)
            }

            self._rt_objs.push(obj)
            self._rt_logs.push("")
        }

        var unsafe *be    = self._backend
        var unsafe *inv_p = self._rt_invs.data()
        var unsafe *log_p = unsafe (unwrap!(self._rt_logs.data_mut()) as unsafe *string)
        var unsafe *ok_p  = unsafe (unwrap!(self._rt_oks.data_mut()) as unsafe *u8)
        var unsafe *rec   = TimeReport::current()
        for var i: usize = 0; i < n; ++i {
            if inv_p[i].get() == &null {
                continue
            }

            self._pool->enqueue(
                kairo::SmallFunction<64>(
                    fn () |be, inv_p, log_p, ok_p, i, rec| {
                        var _kt = TimeReport::Worker(rec)
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
            if !self._rt_logs[i].is_empty() {
                io::eprint(f"{self._rt_logs[i]}")
            }

            if self._rt_oks[i] == (0 as u8) {
                ok = false
                continue
            }

            if !self._rt_ents[i].is_empty() {
                if CompilerInstance::_rt_cache_store(
                    self._rt_objs[i],
                    self._rt_ents[i],
                ) {
                    stored = true
                    self._rt_used.push(self._rt_ents[i].copy())
                }
            }

            self._native_objs.push(self._rt_objs[i].copy())
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                f"emitted object {self._rt_objs[i]}",
            )
        }

        if stored {
            CompilerInstance::_rt_cache_gc(self._rt_cache, self._rt_used)
        }

        return ok
    }

    /// the clang driver words for one C/C++ input, without the
    /// action and the input/output: the backend's roots, everything
    /// FlagTranslator::to_driver spells for this invocation (ending in
    /// --cxx-flags, so those win), then the runtime root.
    priv fn _native_words(self, const k: InputKind) -> cxx::std::vector<string> {
        return self._native_words_for(self._backend, k)
    }

    /// _native_words against a given backend: --print-clang-args builds a
    /// throwaway one, the compile uses the build's.
    prot fn _native_words_for(self,
                              be:      unsafe *ClangBackend,
                              const k: InputKind) -> cxx::std::vector<string> {
        var w  = cxx::std::vector<string>()
        var cl = self.invocation()->codegen.clang_cl()
        // IR and already-preprocessed input search no headers: the roots would
        // only draw clang's "argument unused" warning, once per root.
        if k.needs_headers() {
            for var a in be->sysroot_words(k.is_c_family_c(), ClangSpelling::Driver) {
                w.push_back(
                    if (cl) => (FlagTranslator::cl_word(a)) else => a.copy(),
                )
            }
        }

        // Plugins that do not exist were reported when the backend's
        // configuration was built; here they are only left out.
        var missing = cxx::std::vector<string>()
        for *a in FlagTranslator::to_driver(&*self.invocation(), be->triple(), be->sysroot_clang_triple(), k.type_name(), unsafe &missing) {
            w.push_back(a->copy())
        }

        // `rt/fmt.h` resolves for a C/C++ input exactly as for Lib/rt, and
        // the runtime root comes AFTER the user's -I, as on the cc1 line
        // (_backend_config): a quoted include that exists under both Lib
        // and a user -I dir names the user's file in both clang lines and
        // in the `#include "x.k"` scan (clang_include_dirs). -I is not
        // last-wins, so following --cxx-flags takes nothing from them.
        if k.needs_headers() {
            var rt_root = self._runtime_root()
            if !rt_root.is_empty() {
                self._native_arg(&w, "-I")
                self._native_arg(&w, rt_root)
            }
        }

        return w
    }

    /// appends one of kairo's own words (the action, the input, the
    /// output) to a native line: under clang-cl through /clang:, so it is
    /// read with clang's options as the rest of kairo's words are
    /// (FlagTranslator::cl_line).
    prot fn _native_arg(self, @inout w: cxx::std::vector<string>, const a: string) {
        if self.invocation()->codegen.clang_cl() {
            w.push_back(FlagTranslator::cl_word(a))
        } else {
            w.push_back(a.copy())
        }
    }

    /// the extension of an object a C/C++ input writes when -o does not
    /// name it: clang-cl's .obj under clang-cl, else .o.
    prot fn _native_obj_ext(self) -> string {
        return if (self.invocation()->codegen.clang_cl()) => (".obj") else => ".o"
    }

    /// the driver words a C++ input of this invocation compiles with
    /// (_native_words for a `.cc`), for kals' clangd bridge: clangd
    /// must parse a C++ file that includes a `.k` with kcc's roots
    /// (the sysroot's libc++, the runtime root, the -std), or the
    /// generated header's prelude meets another standard library
    /// (libstdc++ declares `__make_unsigned`, which turns off clang's
    /// builtin of that name that rt/intrinsics.h uses). Empty without
    /// a backend.
    pub fn cxx_driver_words(self) -> cxx::std::vector<string> {
        if self._backend == &null {
            return cxx::std::vector<string>()
        }

        return self._native_words_for(
            self._backend,
            classify_input("input.cc", ""),
        )
    }

    /// cxx_driver_words for a C input (`.c`): the C set kcc compiles
    /// a `.c` with (C roots, C `-std`), for a C source kals' bridge
    /// lists because it reaches a `.k` through a header; the
    /// C++ set's `-std=c++..` is an error for C. Empty without a
    /// backend.
    pub fn c_driver_words(self) -> cxx::std::vector<string> {
        if self._backend == &null {
            return cxx::std::vector<string>()
        }

        return self._native_words_for(
            self._backend,
            classify_input("input.c", ""),
        )
    }

    priv fn _native_jobs(self) -> unsafe *ClangJobs {
        if self._jobs == &null {
            var exe = Path::join_str(Path::parent_of(env::exe_path()), "clang")
            self._jobs = unsafe (@create ClangJobs(self._backend, exe) as unsafe *ClangJobs)
            self._kincludes = unsafe (@create DriverIncludeSource(
                self._sm,
                self._g_scope,
                if (self._pp != &null) => (self._pp->get_symbol_table()) else => &null,
                !self.invocation()->frontend.stops_at_parse() || self.kairo_feeds_includes(),
            ) as unsafe *DriverIncludeSource)

            var *cgo = &self.invocation()->codegen
            if cgo->sema_agreement != 0 {
                self._kincludes->agree_start(
                    cgo->sema_agreement_repair != 0,
                    self.invocation()->frontend.verbose,
                )
            }

            self._jobs->includes = self._kincludes
        }

        return self._jobs
    }

    /// What the Sema agreement pass found in the Kairo streams the last
    /// run's C++ inputs included: I012W at the Kairo call, through the
    /// context of the Kairo file, unless the run only counts.
    priv fn _report_include_agreement(self) {
        if self._kincludes == &null {
            return
        }

        var *cgo = &self.invocation()->codegen
        var says = sema_agree_reports(
            cgo->sema_agreement,
            cgo->test_sema_agreement_quiet,
        )

        for var i: usize = 0; i < self._kincludes->agree_found.size(); ++i {
            var unsafe *ctx = self._kincludes->agree_ctx[i]
            if says && ctx != &null {
                agree_emit(ctx, self._kincludes->agree_found[i])
                ctx->diag_sink.drain_into(
                    unsafe (self._diag as unsafe *DiagEngine),
                    unsafe (self._sm as unsafe *SourceManager),
                )
            }
        }

        self._kincludes->agree_found.clear()
        self._kincludes->agree_ctx.clear()
    }

    /// One driver run for one input; a failure clang did not explain itself
    /// (an external tool, an empty plan) is reported here.
    priv fn _run_native(self, const k: InputKind, @inout words: cxx::std::vector<string>) -> bool {
        var unsafe *jobs = self._native_jobs()
        var        ok    = jobs->run(words)
        jobs->diags.drain_into(
            unsafe (self._diag as unsafe *DiagEngine),
            unsafe (self._sm as unsafe *SourceManager),
        )

        self._report_include_agreement()

        if ok {
            return true
        }

        if !jobs->error.is_empty() {
            self._diag->report(DiagID::U011E, f"{k.path}: {jobs->error}").emit()
        }

        return false
    }

    /// compiles the command line's C, C++, Objective-C and IR inputs
    /// through clang's driver, for the run's action:
    ///
    ///          --preprocess       -E, to -o or stdout
    ///          --syntax-only,
    ///          --type-check-only  -fsyntax-only (C++ has no separate stage)
    ///          otherwise          each --emit kind: <dir>/<stem>.o .s .ll .bc
    ///                             (-c / -S / -S -emit-llvm / -c -emit-llvm);
    ///                             the .o files join the link.
    ///
    ///        -o names the output only when it is the build's one output.
    prot fn _compile_sources(self, const natives: [InputKind]) -> bool {
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
            for const *k in natives {
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
                self._native_arg(&w, if (pp) => ("-E") else => "-fsyntax-only")
                if pp && !single.is_empty() {
                    if natives.size() != 1 {
                        self._diag->report(
                            DiagID::I004F,
                            f"-o {single} names one output, but this build preprocesses {natives.size()} inputs",
                        ).emit()
                        return false
                    }

                    self._native_arg(&w, "-o")
                    self._native_arg(&w, single)
                }

                self._native_arg(&w, "-x")
                self._native_arg(&w, k->type_name())
                self._native_arg(&w, k->path)
                ok = self._run_native(*k, &w) && ok
            }

            return ok
        }

        // What each input writes (--emit), the same kinds and extensions a
        // Kairo TU writes, one driver run each.
        var kinds: [EmitKind]
        var exts:  [string]
        if fe->emit_obj {
            kinds.push(EmitKind::Obj)
            exts.push(self._native_obj_ext())
        }

        if fe->emit_asm {
            kinds.push(EmitKind::Asm)
            exts.push(".s")
        }

        if fe->emit_llvm_ir {
            kinds.push(EmitKind::LLVMIR)
            exts.push(".ll")
        }

        if fe->emit_llvm_bc {
            kinds.push(EmitKind::LLVMBC)
            exts.push(".bc")
        }

        // A header writes one .pch whatever --emit says.
        var n_out = self.kairo_input_count() * kinds.size() + self._header_inputs
        if !single.is_empty() && n_out > 1 {
            self._diag->report(
                DiagID::I004F,
                f"-o {single} names one output, but this build emits {n_out}; use --cache-dir <dir> for them",
            ).emit()
            return false
        }

        var dir = self.object_dir()

        var ok = true
        for const *k in natives {
            if k->cls == InputClass::Header {
                // clang's own answer to a header input: a precompiled header,
                // named after the whole file (foo.h -> foo.h.pch) so foo.h
                // and foo.c never collide. Never linked.
                var pch = single.copy()
                // A linking run's object dir may be a temporary one it
                // deletes; the .pch is an output the user asked for, so it is
                // kept: --cache-dir if given, else the working directory.
                var pdir = dir.copy()
                if self._obj_tmp {
                    pdir = "."
                }

                if pch.is_empty() {
                    pch = pdir + "/" + Path(k->path).filename() + ".pch"
                }

                Path::make_parent_dirs(pch)
                var hw = self._native_words(*k)
                self._native_arg(&hw, "-c")
                self._native_arg(&hw, "-x")
                self._native_arg(&hw, k->type_name())
                self._native_arg(&hw, k->path)
                self._native_arg(&hw, "-o")
                self._native_arg(&hw, pch)
                ok = self._run_native(*k, &hw) && ok
                continue
            }

            for var i: usize = 0; i < kinds.size(); ++i {
                var out = single.copy()
                if out.is_empty() {
                    out = dir.copy() + "/" + Path(k->path).stem() + exts[i]
                }

                Path::make_parent_dirs(out)
                var w    = self._native_words(*k)
                var kind = kinds[i]
                if kind == EmitKind::Asm {
                    self._native_arg(&w, "-S")
                } else if kind == EmitKind::LLVMIR {
                    self._native_arg(&w, "-S")
                    self._native_arg(&w, "-emit-llvm")
                } else if kind == EmitKind::LLVMBC {
                    self._native_arg(&w, "-c")
                    self._native_arg(&w, "-emit-llvm")
                } else {
                    self._native_arg(&w, "-c")
                }

                self._native_arg(&w, "-x")
                self._native_arg(&w, k->type_name())
                self._native_arg(&w, k->path)
                self._native_arg(&w, "-o")
                self._native_arg(&w, out)
                var one = self._run_native(*k, &w)
                ok = one && ok
                if one && kind == EmitKind::Obj {
                    self._native_objs.push(out.copy())
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"emitted object {out}",
                    )
                }
            }
        }

        return ok
    }

    /// the directory the runtime is included and compiled from: the
    /// builtin root's parent -- Lib/ in the tree, <resource-dir>
    /// installed -- so `rt/fmt.h` names Lib/rt/fmt.h from anywhere. The
    /// builtin root is found as the import resolver finds it:
    /// --builtins-dir, else <resource-dir>/builtin. "" when none.
    prot fn _runtime_root(self) -> string {
        var broot = self._builtin_root()
        if broot.is_empty() {
            return ""
        }

        // A trailing '/' would make parent_path answer "a/builtin" for
        // "a/builtin/"; strip it so both spellings name Lib/.
        return Path::parent_of(LinkText::strip_slash(broot.copy()))
    }

    /// the runtime's C/C++ sources: every one directly in
    /// <runtime root>/rt. No root, no runtime. Sorted, so object
    /// order does not follow readdir.
    prot fn _runtime_sources(self) -> [InputKind] {
        var out:  [InputKind]
        var rroot             = self._runtime_root()
        if rroot.is_empty() {
            return out
        }

        var root = Path::join_str(rroot, ResourceLayout::rt_subdir())
        var ec: cxx::std::error_code
        var it = llvm::sys::fs::directory_iterator(
            llvm::Twine(kairo::sref(root)),
            &ec,
            true,
        )

        var end = llvm::sys::fs::directory_iterator()

        for ; ec.value() == 0 && it != end; it.increment(&ec) {
            if Path::type_of_entry(*it) != FileType::regular_file {
                continue
            }

            var p = it->path()
            // The same classifier as a command-line input: rt holds C and
            // C++ only, and a stray header or README must not compile.
            var k = classify_input(
                string(
                    unsafe ((p.data() as unsafe *const u8) as *const u8),
                    p.size(),
                ),
                "",
            )

            if k.cls == InputClass::Source {
                out.push(k)
            }
        }

        out.sort_by(input_kind_before)

        return out
    }

    /// every file the runtime's sources include from the vendored
    /// mimalloc (<runtime root>/rt/mimalloc/{src,include}, recursive),
    /// for the library manifest.
    ///
    /// rt/mimalloc.c is one line of #include into the submodule:
    /// a submodule bump changes these and never mimalloc.c, so a
    /// manifest of _runtime_sources() alone would keep a cached
    /// runtime object built from the old mimalloc. Sorted, so the
    /// manifest does not follow readdir.
    prot fn _runtime_deps(self) -> [string] {
        var out:  [string]
        var rroot          = self._runtime_root()
        if rroot.is_empty() {
            return out
        }

        var subs: [string]
        subs.push(ResourceLayout::mimalloc_src_subdir())
        subs.push(ResourceLayout::mimalloc_include_subdir())
        for *sub in subs {
            var root                      = Path::join_str(rroot, sub->copy())
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
                out.push(
                    string(
                        unsafe ((p.data() as unsafe *const u8) as *const u8),
                        p.size(),
                    ),
                )
            }
        }

        out.sort()

        return out
    }

    priv static fn _parent_dir(const path: string) -> string {
        return Path::parent_of(path)
    }
}
