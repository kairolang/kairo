/// --- The Kairo Project ------------------------ Driver/CompilerLink.k --- ///
///
///   CompilerInstance, part: outputs and the link. _plan_outputs decides
///   once per batch what -o names and where objects go; the checks that
///   only a link makes (one script, one global allocator); then the link
///   itself through API::Link. An `extend` of the class in
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

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/TargetParser/Host.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::Link::{
    Link,
    LinkResult,
}
import API::LinkABI::LinkABI
import API::LinkDiag::{
    LinkDiag,
    LinkMessage,
    LinkSeverity,
}
import API::LinkJob::LinkJob
import API::Text::LinkText
import API::Toolchain::Toolchain
import AST::LangItems::{
    LangAttrs,
    LowerTargets,
}
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Driver::BatchResult::BatchResult
import Driver::CompilerCache
import Driver::CompilerInstance::CompilerInstance
import Driver::InputKinds::{
    InputClass,
    classify_input,
}
import Support::FileIO::Path::Path
import Support::TimeReport::TimeRegion
import std::env
import std::io

extend CompilerInstance {
    /// # Linking

    /// \brief decides once per batch what -o names and where objects go.
    ///
    /// \details -o is always ONE output file: the executable or library when
    ///          this run links, the single object under -c. Objects go to
    ///          --cache-dir (kept); without it, a linking run uses a temp dir
    ///          it removes afterwards (`<output>.kobj` under --save-temps),
    ///          and a -c run uses the working directory. -o naming a
    ///          directory is an error: that is --cache-dir's job.
    ///
    /// \return false on a fatal planning error; nothing may compile.
    prot fn _plan_outputs(self) -> bool {
        var *lk = &self.invocation()->linker
        var out = self.invocation()->frontend.output
        self._link_out    = ""
        self._obj_dir     = lk->cache_dir
        self._obj_tmp     = false
        self._emit_beside = false
        self._obj_listed  = true

        // Classified and counted here, before any TU runs: -o under -c names
        // the one USER translation unit, and codegen of the first input must
        // already know whether a second one is coming. An input nothing can
        // build stops the run before anything compiles, every one reported.
        self._kairo_inputs = 0
        self._inputs.clear()
        var bad  = false
        var n_in = self.invocation()->input_files.size()
        for var i: usize = 0; i < n_in; ++i {
            var path_str = self.invocation()->input_files[i]
            var k        = classify_input(path_str, self.invocation()->input_lang(i))
            if k.cls == InputClass::Unsupported
                || k.cls == InputClass::Unknown
                || k.cls == InputClass::BadLanguage {
                self._diag->report(DiagID::U011E, f"{path_str}: {k.why}").emit()
                bad = true
            }

            if k.cls == InputClass::Kairo {
                self._kairo_inputs += 1
            }

            if k.cls == InputClass::Source {
                self._source_inputs += 1
            }

            if k.cls == InputClass::Header {
                self._header_inputs += 1
            }

            self._inputs.push_back(k)
        }

        if bad {
            return false
        }

        // A C/C++ input's outputs are named <dir>/<stem>.<ext>, and a
        // header's <dir>/<file>.pch. Two inputs that name one output would
        // write one file; clang silently overwrites, this says so (a
        // deliberate deviation). A Kairo entry TU of the same stem is no
        // clash: it writes <stem>.k.<ext> instead (kairo_object_stem), which
        // is the common case of a foo.cc that includes foo.k. Only for runs that write
        // files: --preprocess goes to stdout, the check-only runs write none.
        var *fe_plan = &self.invocation()->frontend
        if !fe_plan->stops_before_codegen() {
            for var a: usize = 0; a < self._inputs.size(); ++a {
                var ka    = self._inputs[a]
                var a_hdr = ka.cls == InputClass::Header
                if ka.cls != InputClass::Source && !a_hdr {
                    continue
                }

                var na = if (a_hdr) => (Path(ka.path).filename()) else => Path(ka.path).stem()
                for var b: usize = 0; b < self._inputs.size(); ++b {
                    if b == a {
                        continue
                    }

                    var kb    = self._inputs[b]
                    var b_hdr = kb.cls == InputClass::Header
                    var nb    = ""
                    if a_hdr {
                        if !b_hdr {
                            continue
                        }

                        nb = Path(kb.path).filename()
                    } else {
                        if kb.cls != InputClass::Source {
                            continue
                        }

                        nb = Path(kb.path).stem()
                    }

                    if nb != na {
                        continue
                    }

                    if b < a { // reported once
                        continue
                    }

                    self._diag->report(
                        DiagID::U013E,
                        f"{ka.path} and {kb.path} both write '{na}' outputs; rename one, or compile them in separate runs",
                    ).emit()
                    bad = true
                }
            }
        }

        if bad {
            return false
        }

        if !out.empty() && (LinkText::ends_with(out, "/") || LinkFS::is_dir(out)) {
            self._diag->report(
                DiagID::I004F,
                f"-o {out} is a directory; -o names the output file, and object files go to --cache-dir <dir>",
            ).emit()
            return false
        }

        if lk->emit_scope != "graph" && lk->emit_scope != "inputs" {
            self._diag->report(
                DiagID::U003E,
                f"invalid --emit-scope value '{lk->emit_scope}'; accepted: graph, inputs",
            ).emit()
            return false
        }

        // --emit: an item that is no kind at all is an error naming the set;
        // one the flag accepts but codegen does not produce yet is an error
        // too, rather than a run that silently writes nothing for it.
        var *fe = &self.invocation()->frontend
        for *it in fe->emit_unknown {
            self._diag->report(
                DiagID::U003E,
                f"invalid --emit value '{(*it)}'; accepted: obj, asm, llvm-ir, llvm-bc",
            ).emit()
        }

        for *it in fe->emit_unsupported {
            self._diag->report(
                DiagID::U003E,
                f"--emit={(*it)} is not implemented yet; implemented: obj, asm, llvm-ir, llvm-bc",
            ).emit()
        }

        if fe->emit_unknown.size() > 0 || fe->emit_unsupported.size() > 0 {
            return false
        }

        // Nothing to link unless an input makes an object or is one: a build
        // of headers alone writes their .pch files and stops, as under clang,
        // and its -o names that one output.
        var linkable = false
        for *k in self._inputs {
            if k->cls == InputClass::Kairo
                || k->cls == InputClass::Source
                || k->cls == InputClass::LinkInput {
                linkable = true
            }
        }

        var links = !lk->compile_only
            && !self.invocation()->frontend.stops_before_codegen()
            && linkable
        if !links {
            if self._obj_dir.empty() {
                self._obj_dir = "."
            }

            // -o names this run's one output. Checked here, once, with every
            // count known: a check inside codegen would already have written
            // the first TU's object to -o before a later input proved there
            // were two. A header writes one .pch whatever --emit says.
            if !out.empty() && !fe->stops_before_codegen() {
                var n_kinds: usize = 0
                if fe->emit_obj {
                    n_kinds += 1
                }

                if fe->emit_asm {
                    n_kinds += 1
                }

                if fe->emit_llvm_ir {
                    n_kinds += 1
                }

                if fe->emit_llvm_bc {
                    n_kinds += 1
                }

                var n_out = (self._kairo_inputs + self._source_inputs) * n_kinds + self._header_inputs
                if n_out > 1 {
                    self._diag->report(
                        DiagID::I004F,
                        f"-o {out} names one output, but this build emits {n_out}; use --cache-dir <dir> for them",
                    ).emit()
                    return false
                }
            }

            return true
        }

        self._link_out = if (!out.empty()) => (out) else => "a.out"
        // `--emit obj,asm -o app` (EmitKinds::links): the link needs
        // objects whether or not obj was listed, and the listed kinds are
        // outputs. Under --cache-dir they are kept there with everything
        // else; otherwise the object dir may be a temp one, and the entry
        // TUs write beside the executable instead (emit_beside).
        if fe->emit_asm || fe->emit_llvm_ir || fe->emit_llvm_bc {
            self._obj_listed  = fe->emit_obj
            fe->emit_obj      = true
            self._emit_beside = self._obj_dir.empty()
        }

        if !self._obj_dir.empty() {
            return true
        }

        if lk->save_temps {
            self._obj_dir = self._link_out + ".kobj"
            return true
        }

        self._obj_dir = LinkFS::temp_dir("kairo-obj")
        self._obj_tmp = true
        if self._obj_dir.empty() {
            self._diag->report(
                DiagID::L004F,
                "cannot create a temporary directory for object files",
            ).emit()
            return false
        }

        return true
    }

    /// Where objects go. Always a directory, always set after _plan_outputs.
    fn object_dir(self) -> string {
        return self._obj_dir
    }

    /// The file -o names when it names an object: a -c run with -o. "" when
    /// this run links (-o is the executable then) or there is no -o. Valid
    /// only if the build emits exactly one object; each emitter checks.
    fn kairo_input_count(self) -> usize {
        return self._kairo_inputs + self._source_inputs
    }

    fn kairo_only_input_count(self) -> usize {
        return self._kairo_inputs
    }

    /// \brief the path, minus its extension, an entry TU of input stem
    ///        \p stem writes its --emit outputs to in a linking run that
    ///        listed more kinds than the object, or "" to use the object dir.
    ///
    /// \details `kairo app.k --emit obj,asm -o out/app` writes out/app.o and
    ///          out/app.s, named after the executable; with several Kairo
    ///          inputs each is named after its own stem, in -o's directory.
    ///          Imported modules and the prelude stay in the object dir:
    ///          they are link inputs, not what the user asked to see.
    fn emit_beside(self, const stem: string) -> string {
        if !self._emit_beside || self._link_out.empty() {
            return ""
        }

        var dir = Path::parent_of(self._link_out)
        var name = if (self._kairo_inputs == 1) => (Path::stem_of(self._link_out))
                   else => self.kairo_object_stem(stem)
        if dir.empty() {
            return name
        }

        return dir + "/" + name
    }

    /// False when the objects of an emit_beside run are only link inputs:
    /// --emit did not list obj, so they stay in the object dir, unprinted.
    fn obj_listed(self) -> bool {
        return self._obj_listed
    }

    /// True when this run links and --emit listed kinds beyond the object.
    fn emits_beside_link(self) -> bool {
        var *fe = &self.invocation()->frontend
        return !self._link_out.empty() && (fe->emit_asm || fe->emit_llvm_ir || fe->emit_llvm_bc)
    }

    fn single_object(self) -> string {
        if !self._link_out.empty() {
            return ""
        }

        return self.invocation()->frontend.output
    }

    /// kld beside this binary: the out-of-process fallback, used only after
    /// the in-process linker poisons itself or for an -mllvm link.
    priv fn _kld_path(self) -> string {
        var dir = Path::parent_of(env::exe_path())
        var exe = "kld"
        if llvm::Triple(llvm::sys::getProcessTriple()).isOSWindows() {
            exe = "kld.exe"
        }

        return dir + "/" + exe
    }

    /// The second script of a link is an error at its first statement,
    /// with a note at the first script's (TUResult::script_at). One error
    /// per extra script; the first one found in input order is the one the
    /// others are measured against.
    prot fn _reject_second_script(self, @inout result: BatchResult) {
        var first: isize = -1
        for var i: usize = 0; i < result.tu_results.size(); ++i {
            var r = result.tu_results[i]
            if !r.script_at.is_valid() {
                continue
            }

            if first < 0 {
                first = (i as isize)
                continue
            }

            var p = result.tu_results[first as usize]
            var a = Path(p.path).filename()
            var b = Path(r.path).filename()
            var d = self._diag->report(
                DiagID::SC142E,
                r.script_at.start,
                f"two script files in one program: '{b}' and '{a}' each run top-level statements as 'main'",
            )

            d.first(r.script_at)
            d.note(
                DiagCode(DiagID::SC142N),
                p.script_at.start,
                f"'{a}' is a script: its first top-level statement is here",
            )->first(p.script_at)
            d.emit()
        }
    }

    /// Decides, before any file is walked, whether this program's Kairo
    /// files are compiled with __KAIRO_GLOBAL_ALLOCATOR_SET: the builtin's
    /// Global is System inlined without it, and the kairo_global_* symbols
    /// (whatever file set them) with it. Every TU of one program must agree,
    /// the builtin's too, or the ones that inlined System bypass the
    /// program's allocator; so the answer is one bit for the run, settled
    /// here rather than when the setting file is parsed, which may be after
    /// the builtin and earlier inputs were already compiled.
    ///
    /// On with --global-allocator-set or a -D naming the macro (same
    /// meaning), or when a linked object's ABI note says its file set it,
    /// else when a file the inputs reach writes
    /// `@set_global_allocator` at the start of a line (the parser takes it
    /// nowhere else, so a comment or a doc line naming it does not count).
    /// That scan reads the import graph the preprocessor would walk, which is
    /// the whole program under --emit-scope=graph; under inputs (kcc -c) it
    /// is only this run's share, and a file set apart needs the flag -- the
    /// ABI note check at the link catches a build that forgot it.
    prot fn _settle_global_allocator(self) {
        var *pp  = &self.invocation()->pp
        var mac  = LowerTargets::global_alloc_set_macro()
        var hand = false
        for *d in pp->defines {
            if *d == mac || LinkText::starts_with(*d, mac + "=") {
                hand = true
            }
        }

        if hand {
            pp->global_allocator_set = true
        }

        if !pp->global_allocator_set && self._pp != &null {
            var nk: usize = 0
            for *k in self._inputs {
                if k->cls == InputClass::LinkInput
                    || k->cls == InputClass::Source
                    || k->cls == InputClass::Header {
                    continue
                }

                nk += 1
            }

            // _kairo_order's fid-0 placeholder, which it can only add while
            // nothing is loaded: loading the inputs here first must leave
            // fid 0 where it would have been.
            if nk >= 2 && self._sm->file_count() == 0 {
                self._sm->load_virtual(
                    Path(r"<kairo-batch>"),
                    unsafe (self._fid0_text.raw() as kairo::std::ConstPtr<u8>),
                    self._fid0_text.size(),
                )
            }

            var checked = llvm::DenseSet<u64>()
            for *k in self._inputs {
                if pp->global_allocator_set {
                    break
                }

                // An object of a file that set it (its ABI note says so): a
                // link of separately built objects needs the library built
                // with the define as much as a graph build does.
                if k->cls == InputClass::LinkInput {
                    if LinkABI::sets_global_allocator(k->path) {
                        pp->global_allocator_set = true
                    }

                    continue
                }

                if k->cls == InputClass::Source || k->cls == InputClass::Header {
                    continue
                }

                if CompilerInstance::_file_sets_global_allocator(k->path) {
                    pp->global_allocator_set = true
                    break
                }

                // A missing input is its action's error to report, once.
                if !LinkFS::is_file(k->path) {
                    continue
                }

                var f = (self._sm->load_file(Path(k->path)))
                if f == u32::MAX {
                    continue
                }

                var r = self._pp->reach(f)
                for g in r {
                    // Each file once: inputs share most of their closures,
                    // and re-reading every file per input was quadratic.
                    if checked.contains(g) {
                        continue
                    }

                    checked.insert(g as u64)
                    if CompilerInstance::_file_sets_global_allocator(self._sm->get_filename(g)) {
                        pp->global_allocator_set = true
                        break
                    }
                }
            }
        }

        // A -D the user wrote is registered already, by the constructor.
        if pp->global_allocator_set && !hand && self._pp != &null {
            self._pp->define_late(mac)
        }
    }

    /// true when \p path's text has a line starting (after blanks) with
    /// `@set_global_allocator`. An unreadable path (a virtual file) is false.
    priv static fn _file_sets_global_allocator(const path: string) -> bool {
        var text = ""
        if !LinkFS::read(path, &text) {
            return false
        }

        var pat       = "@" + LangAttrs::set_global_allocator()
        var n         = text.size()
        var i:  usize = 0
        while i < n {
            while i < n && (text[i] == (' ' as u8) || text[i] == ('\t' as u8)) {
                i += 1
            }

            var hit = i + pat.size() <= n
            for var j: usize = 0; hit && j < pat.size(); ++j {
                if text[i + j] != pat[j] {
                    hit = false
                }
            }

            if hit {
                return true
            }

            while i < n && text[i] != ('\n' as u8) {
                i += 1
            }

            i += 1
        }

        return false
    }

    /// A program has one global allocator: a second file of the link that
    /// writes `@set_global_allocator` is an error at it, with a note at the
    /// first (TUResult::global_alloc_at). kld would refuse the link anyway
    /// (both define the kairo_global_* symbols strongly), but naming the
    /// two lines beats naming two objects. Objects built apart still reach
    /// kld, which _global_alloc_clash words the same way.
    prot fn _reject_second_global_allocator(self, @inout result: BatchResult) {
        var first: isize = -1
        for var i: usize = 0; i < result.tu_results.size(); ++i {
            var r = result.tu_results[i]
            if !r.global_alloc_at.is_valid() {
                continue
            }

            if first < 0 {
                first = (i as isize)
                continue
            }

            var p = result.tu_results[first as usize]
            // Two inputs that import one module that sets it: one file.
            if p.global_alloc_file == r.global_alloc_file {
                continue
            }

            var a = Path(p.global_alloc_file).filename()
            var b = Path(r.global_alloc_file).filename()
            var d = self._diag->report(
                DiagID::SC138E,
                r.global_alloc_at.start,
                f"two files set the global allocator: '{b}' and '{a}'; a program has one",
            )

            d.first(r.global_alloc_at)
            d.note(DiagCode(DiagID::SC138N), p.global_alloc_at.start, f"'{a}' sets it here")->first(
                p.global_alloc_at,
            )

            d.emit()
        }
    }

    /// kld's duplicate-symbol errors for the kairo_global_* symbols (one per
    /// symbol, five in all) as ONE error saying what they mean: two of the
    /// linked objects were built from files that set the global allocator.
    /// The objects are named as kld names them (LinkDiag::definers), and
    /// each as its source file when this run compiled it. Every other
    /// message passes through unchanged.
    priv fn _global_alloc_clash(self,
                                @inout result: BatchResult,
                                @inout msgs:   cxx::std::vector<LinkMessage>) {
        var out  = cxx::std::vector<LinkMessage>()
        var said = false
        var sym  = LowerTargets::global_alloc_symbol_prefix()
        for var m: LinkMessage in msgs {
            var hit = m.severity == LinkSeverity::Error
                && LinkText::find(m.text, "duplicate symbol: ", 0) < m.text.size()
                && LinkText::find(m.text, sym, 0) < m.text.size()
            if !hit {
                out.push_back(m)
                continue
            }

            if said {
                continue
            }

            said = true
            var who   = LinkDiag::definers(m.text)
            var names = cxx::std::vector<string>()
            for *o in who {
                names.push_back(self._object_module(*o))
            }

            var text = "the global allocator is set twice (@set_global_allocator)"
            if names.size() >= 2 {
                text = text + f": by {names[0]} and by {names[1]}"
            }

            text = text + "; a program has one, so exactly one linked file may set it"
            out.push_back(LinkDiag::make(LinkSeverity::Error, text))
        }

        msgs = out
    }

    /// An object kld named, as the module it was built from when this run
    /// built it: <object dir>/a/b.o is module `a::b` (each module's object
    /// sits at its path under the object dir). Any other object, as given.
    priv fn _object_module(self, o: string) -> string {
        var dir = self.object_dir()
        if dir.empty() || !LinkText::starts_with(o, dir + "/") || !LinkText::ends_with(o, ".o") {
            return o
        }

        var rel = LinkText::slice(o, dir.size() + 1, o.size() - 2)
        var m   = ""
        for var i: usize = 0; i < rel.size(); ++i {
            if rel[i] == ('/' as u8) || rel[i] == ('\\' as u8) {
                m += "::"
            } else {
                m.push_back(rel[i])
            }
        }

        return f"module '{m}' ({o})"
    }

    /// Plans, echoes under -v, runs. The object list is exactly what this
    /// run emitted, never a directory glob: a reused --cache-dir can hold
    /// objects from modules that no longer exist.
    prot fn _link(self, @inout result: BatchResult) {
        var _t = TimeRegion("Link")

        // lld::lldMain is not reentrant and resets process-global state
        // (CommonLinkerContext, cl options, parallel::strategy); it must run
        // with nothing else in the process inside clang/LLVM. Every group is
        // drained here, not just the ones this driver knows it enqueued, so a
        // late pool task (a header build, a clang startup) can never overlap
        // the link, and no object's writer is still open when lld mmaps it.
        self._pool->wait_all()

        // MinGW's pthreads are not in its libc: a program whose Kairo code
        // imports pthread.h links winpthread, as `-l winpthread` written by
        // hand would (`pthread` is MinGW's alias for the same archive, so a
        // hand-written one already covers it). A copy of the options, so
        // the invocation stays what the user asked for.
        var lk_eff = self.invocation()->linker
        if self._backend != &null {
            var wnorm = llvm::Triple::normalize(kairo::sref(self._backend->triple()))
            var wants = false
            for *tr in result.tu_results {
                if tr->ffi_pthread {
                    wants = true
                }
            }

            if wants && llvm::Triple(llvm::Twine(wnorm)).isWindowsGNUEnvironment() {
                var have = false
                for *l in lk_eff.link_libs {
                    if LinkText::ends_with(*l, "winpthread") || LinkText::ends_with(*l, "pthread") {
                        have = true
                    }
                }

                if !have {
                    lk_eff.link_libs.push_back("winpthread")
                }
            }
        }

        var *lk = &lk_eff
        var job = LinkJob(&self.invocation()->target, lk)
        job.output   = self._link_out
        job.threads  = (self._pool->get_thread_count() as u32)
        job.kld_path = self._kld_path()
        // lld's LTO backend defaults to -O2 regardless of how the bitcode was
        // produced; the link must be told the level the objects were built at.
        job.lto       = self.invocation()->codegen.lto
        job.opt_level = self.invocation()->codegen.opt_level
        {
            // As the runtime cache: a cache root that cannot be made (a
            // read-only home, a sandbox) means no cache, not a failed link --
            // lld errors on a cache dir it cannot create.
            var croot = CompilerInstance::_cache_root()
            if !croot.empty() {
                var ldir = croot + "/lto"
                if LinkFS::make_dirs(ldir) {
                    job.lto_cache_dir = ldir
                }
            }
        }

        for *tr in result.tu_results {
            for *obj in tr->objects {
                job.add_object(*obj)
            }
        }

        for *obj in self._native_objs {
            job.add_object(*obj)
        }

        for *obj in self._link_inputs {
            job.add_object(*obj)
        }

        for *obj in self._lib_lazy {
            job.lazy_objects.push_back(*obj)
        }

        job.lazy_archive = self._lib_archive

        // Emission is synchronous (ExecuteAction closes the output through
        // clearOutputFiles before returning), so a missing object here is a
        // driver bug, not a race. Say so instead of letting lld mmap nothing.
        var missing = false
        for *obj in job.objects {
            if !LinkFS::is_file(*obj) {
                self._diag->report(
                    DiagID::L003E,
                    f"object {(*obj)} was never written; not linking",
                ).emit()
                missing = true
            }
        }

        if missing {
            return
        }

        var tc      = Toolchain()
        var argv    = cxx::std::vector<string>()
        var msgs    = cxx::std::vector<LinkMessage>()
        var planned = Link::plan(&job, &tc, &argv, &msgs)
        self._report_link(&msgs)
        if !planned {
            return
        }

        if lk->print_ld_args {
            io::println(f"{Link::render(&argv)}")
            return
        }

        if self.invocation()->frontend.verbose {
            self._diag->report(DiagID::L005V, Link::render(&argv)).emit()
        }

        var res = LinkResult{}
        Link::execute(&job, &argv, &res)
        self._global_alloc_clash(&result, &res.messages)
        self._report_link(&res.messages)
        if !res.stdout_text.empty() {
            io::println(f"{res.stdout_text}")
        }

        if res.ok {
            kairo::Logger::info(kairo::Logger::Stage::Driver, f"linked {self._link_out}")
        }
    }

    /// LinkMessage -> the placeholder L001 codes. Verbose and Debug only
    /// under -v.
    prot fn _report_link(self, @inout msgs: cxx::std::vector<LinkMessage>) {
        var verbose = self.invocation()->frontend.verbose
        for var m: LinkMessage in msgs {
            if m.severity == LinkSeverity::Fatal {
                self._diag->report(DiagID::L002F, m.text).emit()
            } else if m.severity == LinkSeverity::Error {
                self._diag->report(DiagID::L002E, m.text).emit()
            } else if m.severity == LinkSeverity::Warning {
                self._diag->report(DiagID::L002W, m.text).emit()
            } else if m.severity == LinkSeverity::Note {
                self._diag->report(DiagID::L002N, m.text).emit()
            } else if m.severity == LinkSeverity::Remark {
                self._diag->report(DiagID::L002R, m.text).emit()
            } else if m.severity == LinkSeverity::Info {
                self._diag->report(DiagID::L002I, m.text).emit()
            } else if m.severity == LinkSeverity::Verbose {
                if verbose {
                    self._diag->report(DiagID::L002V, m.text).emit()
                }
            } else if m.severity == LinkSeverity::Debug {
                if verbose {
                    self._diag->report(DiagID::L002D, m.text).emit()
                }
            }
        }
    }
}
