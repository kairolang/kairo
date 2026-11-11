/// --- The Kairo Project ----------------------- Driver/ModuleRecords.k --- ///
///
///   \brief Incremental Sema, phase 2 (Compiler/Spec/IncrementalSema.md#phase-2):
///          per-module records and the run manifest under
///          <cache-dir>/kairo-cache-v<CACHE_SCHEMA>/mod/, and the all-or-nothing
///          hit decision that lets a run whose inputs did not change skip the
///          frontend (parse, Sema, lowering, emit, the object-key fill) and go
///          to the link with the objects the previous run wrote.
///
///   The HIT decision is the whole-input check, not M(m) over dependency
///   rows: a hit means every input the previous run read is byte-for-byte
///   the same (sources, builtin and std files, every C++ header of every
///   header set, the compiler executable), the command line, the working
///   directory, the steering environment and the diagnostic renderer are
///   the same, no directory the graph resolves through gained or lost a
///   module, and every object the link takes is still the one written. A
///   miss of any kind runs the full pipeline, as without the flag, and
///   rewrites the records. Phase 3 reads the per-module records (interface,
///   dependency rows, header hashes, object keys) that this phase only
///   stores.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringSet.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "Native/KObjCache.hh"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "chrono"

import API::FS::*
import Driver::ObjectCache::ObjectCache
import Driver::ObjectCache::CACHE_SCHEMA
import Sema::Incremental::Plan::PlanModule
import Support::FileIO::Path::Path
import std::env

/// Bumped by any change to the manifest or record format, or to what the
/// hit decision compares.
pub
const INCR_SEMA_SCHEMA: u32 = 2

/// The environment variables a run can read that steer which files it finds
/// or how it renders (sysroot, SDK, include search, colour). Others are not
/// keyed (Compiler/Spec/IncrementalSema.md#phase-2, "not covered").
fn incr_env_names() -> cxx::std::vector<string> {
    var v = cxx::std::vector<string>()
    v.push_back("KAIRO_SYSROOT_SHARE")
    v.push_back("KAIRO_SYSROOT_CACHE")
    v.push_back("KAIRO_CACHE_DIR")
    v.push_back("KAIRO_INCR_TEST")
    v.push_back("SDKROOT")
    v.push_back("DEVELOPER_DIR")
    v.push_back("NIX_CFLAGS_COMPILE")
    v.push_back("PKG_CONFIG_SYSROOT_DIR")
    v.push_back("PKG_CONFIG_LIBDIR")
    v.push_back("CPATH")
    v.push_back("C_INCLUDE_PATH")
    v.push_back("CPLUS_INCLUDE_PATH")
    v.push_back("INCLUDE")
    v.push_back("LIB")
    v.push_back("XWIN")
    v.push_back("MSVC_CACHE")
    v.push_back("NO_COLOR")
    v.push_back("TERM")
    return v
}

pub class ModuleRecords {
    /// The flag is on and the run is of a shape a record can stand for.
    pub var on:           bool   = false
    pub var verify:       bool   = false ///< --incr-verify
    pub var paranoid:     bool   = false ///< --incr-paranoid: hash every file, trust no stat
    pub var print_status: bool   = false ///< --print-incr-status
    pub var hit:          bool   = false
    pub var status:       string = ""
    /// <cache-dir>/kairo-cache-v<CACHE_SCHEMA>/mod
    pub var dir: string = ""

    /// What the hit run replays, loaded by check().
    pub var old_diag:    string = ""
    pub var old_warns:   u32    = 0
    pub var old_pthread: bool   = false
    pub var old_objects: cxx::std::vector<string>
    pub var old_mods:    cxx::std::vector<string> ///< "<module>\t<O keys>\t<I(m)>", sorted
    /// What a miss leaves for the re-check plan (Sema/Incremental/Plan.k).
    /// \c plan_base: the only inputs that moved are Kairo sources of the
    /// recorded graph (\c changed, their paths), so the stored rows can say
    /// which modules they reach. Otherwise \c plan_all says why every
    /// module is re-checked: the fallbacks, one per kind of input the rows
    /// cannot see (Compiler/Spec/IncrementalSema.md#phase-3).
    pub var plan_base: bool   = false
    pub var plan_all:  string = ""
    pub var changed:   cxx::std::vector<string>
    /// The recorded run reported an error: its records are a baseline for
    /// the plan and never a hit (an error is not replayed).
    pub var old_errors: bool = false
    /// The console consumer's buffer size and the engine's warning count
    /// when the loop started: what the loop added is what a record holds.
    pub var diag0:  usize = 0
    pub var warns0: u32   = 0

    /// What this run collected, for write(). Filled by the FrontendAction
    /// (modules, keys, header files) and by CompilerInstance (the rest).
    pub var mod_names: cxx::std::vector<string> ///< module path per record
    pub var mod_hash:  cxx::std::vector<string> ///< I(m), parallel
    pub var mod_json:  cxx::std::vector<string> ///< the record body, parallel
    pub var mod_plan:  cxx::std::vector<PlanModule> ///< the plan record, parallel
    pub var errors:    bool = false ///< this run reported an error
    pub var keys:      cxx::std::vector<string> ///< "<module>\t<O(m)>" per codegen job
    pub var hdr_files: cxx::std::vector<string> ///< every header-set file path
    pub var src_files: cxx::std::vector<string> ///< every SourceManager file path
    pub var src_hash:  cxx::std::vector<string> ///< parallel: hash of the bytes the run read ("" = hash the disk)
    pub var roots:     cxx::std::vector<string> ///< the import search roots
    pub var objects:   cxx::std::vector<string>
    pub var pthread:   bool                     = false
    pub var diag:      string                   = ""
    pub var warns:     u32                      = 0

    priv var _f_lines:  string = "" ///< F_sema's parts, one per line
    priv var _manifest: string = ""
    priv var _exe:      string = ""
    priv var _t_start:  u64    = 0
    priv var _seq:      u64    = 0
    /// The manifest as check() parsed it, for the refresh a touched-but-same
    /// file triggers (its new mtime goes back in, so the next hit is a stat).
    priv var _lines:     cxx::std::vector<string>
    priv var _refreshed: bool = false

    fn ModuleRecords(self) = default

    /// \brief F_sema and the paths, for one input under \p cache_dir.
    ///
    /// \param words  the command line as given (argv, or kcc's words), in
    ///               order: every flag that can change Sema, the emitted
    ///               objects or what is printed is in it, so the whole line
    ///               is keyed rather than a list of the flags that matter (a
    ///               false miss costs a run, a false hit a miscompile). The
    ///               observation flags of this feature are left out.
    /// \param color  the diagnostic renderer's colour decision.
    pub fn setup(self,
                 const cache_dir: string,
                 const words:     cxx::std::vector<string>,
                 const input:     string,
                 const output:    string,
                 const format:    string,
                 color:           bool) -> bool {
        self.on = false
        if cache_dir.empty() || words.empty() {
            return false
        }

        self._t_start = ModuleRecords::_now()
        var args = ""
        for var i: usize = 1; i < words.size(); ++i {
            var w = words[i]
            if w == "--incremental-sema" || w == "--incr-verify" || w == "--print-incr-status"
                || w == "--incr-paranoid" || w == "--time-passes" || w == "--print-incr-plan" {
                continue
            }

            args += w + "\n"
        }

        var envs = ""
        for var n: string in incr_env_names() {
            envs += n + "=" + LinkFS::env(n) + "\n"
        }

        var ver = string(unsafe ((kairo::version_string() as unsafe *const u8) as *const u8))
        self._f_lines = f"f.schema {INCR_SEMA_SCHEMA}.{CACHE_SCHEMA}\n"
        self._f_lines += "f.version " + ObjectCache::clean(ver) + "\n"
        self._f_lines += "f.args " + ObjectCache::hash(args) + "\n"
        self._f_lines += "f.cwd " + ObjectCache::hash(Path::cwd().path_data) + "\n"
        self._f_lines += "f.env " + ObjectCache::hash(envs) + "\n"
        self._f_lines += "f.diag " + format + (if (color) => (" color") else => " plain") + "\n"
        // The compiler is a file input like any other (stat, then content),
        // not a hash in F: hashing a debug compiler on every run would cost
        // more than the hit saves. KAIRO_INCR_TEST_EXE stands in for it in
        // the tests, which cannot swap the binary under lit.
        self._exe = LinkFS::env("KAIRO_INCR_TEST_EXE")
        if self._exe.empty() {
            self._exe = env::exe_path()
        }

        self.dir       = cache_dir + f"/kairo-cache-v{CACHE_SCHEMA}/mod"
        self._manifest = self.dir + "/run-" + ObjectCache::hash(input + "\n" + output) + ".txt"
        self.on        = true
        return true
    }

    /// \brief true when the manifest says this run's inputs are the ones
    ///        the previous run read; \c status names the first difference.
    pub fn check(self) -> bool {
        self.hit       = false
        self.plan_base = false
        self.plan_all  = "no record"
        self.changed.clear()
        var text = ""
        if !LinkFS::read(self._manifest, &text) {
            self.status = "miss: no record"
            return false
        }

        // The diagnostic stream is the tail, length-prefixed: it may hold
        // any byte, a newline included.
        var at   = ModuleRecords::_find(text, "\ndiag ")
        var tail = ""
        if at == usize::MAX || !text.ends_with("\nend\n") {
            self.status = "miss: damaged record"
            return false
        }

        {
            var p = at + 6
            var n: u64 = 0
            while p < text.size() && text[p] != ('\n' as u8) {
                n = n * 10 + ((text[p] - ('0' as u8)) as u64)
                p += 1
            }

            p += 1
            if p + (n as usize) + 4 > text.size() {
                self.status = "miss: damaged record"
                return false
            }

            tail = text.subslice(p, n as usize)
        }

        self._lines = ModuleRecords::_split(text.subslice(0, at + 1))
        if self._lines.empty() || self._lines[0] != f"kairo-incr-run {INCR_SEMA_SCHEMA}" {
            self.status = "miss: record of another schema"
            return false
        }

        // F_sema first, by part, so the reason says which part moved.
        var have_f = ""
        for var l: string in self._lines {
            if l.starts_with("f.") {
                have_f += l + "\n"
            }
        }

        if have_f != self._f_lines {
            var mine = ModuleRecords::_split(self._f_lines)
            for var l: string in mine {
                if ModuleRecords::_find(have_f, l + "\n") == usize::MAX {
                    var sp = ModuleRecords::_find(l, " ")
                    var part = if (sp == usize::MAX) => (l) else => l.subslice(0, sp)
                    if part == "f.args" {
                        self.status = "miss: flags changed"
                    } else if part == "f.env" {
                        self.status = "miss: environment changed"
                    } else if part == "f.version" {
                        self.status = "miss: compiler changed (version)"
                    } else {
                        self.status = "miss: " + part + " changed"
                    }

                    self.plan_all = self.status.subslice(6, self.status.size() - 6)
                    return false
                }
            }

            self.status   = "miss: flags changed"
            self.plan_all = "flags changed"
            return false
        }

        // The status is the FIRST difference, as it always was. A changed
        // Kairo source does not end the scan: the plan wants every one of
        // them, and to know that nothing else moved. Anything else does (an
        // added or removed file, a header, the compiler, a directory): the
        // dependency rows say nothing about it, so there is no plan to make.
        self.old_objects.clear()
        self.old_mods.clear()
        self.old_errors = false
        self.plan_all   = ""
        var nmods: usize = 0
        var missed       = false
        for var i: usize = 0; i < self._lines.size(); ++i {
            var l = self._lines[i]
            if l.starts_with("file ") || l.starts_with("exe ") || l.starts_with("obj ") {
                var why = self._check_file(i)
                if !why.empty() {
                    if !missed {
                        self.status = "miss: " + why
                        missed      = true
                    }

                    var p = ModuleRecords::_field_rest(l, 4)
                    if l.starts_with("file ") && why.starts_with("changed: ") && p.ends_with(".k") {
                        self.changed.push_back(p)
                        continue
                    }

                    // The link's input, which no module's check reads.
                    if l.starts_with("obj ") {
                        continue
                    }

                    self.plan_all = why
                    return false
                }

                if l.starts_with("obj ") {
                    self.old_objects.push_back(ModuleRecords::_field_rest(self._lines[i], 4))
                }
            } else if l.starts_with("dir ") {
                var h = ModuleRecords::_field(l, 1)
                var d = ModuleRecords::_field_rest(l, 2)
                if ModuleRecords::_listing(d) != h {
                    if !missed {
                        self.status = "miss: graph changed: " + d
                    }

                    self.plan_all = "graph changed: " + d
                    return false
                }
            } else if l.starts_with("mod ") {
                nmods += 1
                self.old_mods.push_back(l.subslice(4, l.size() - 4))
            } else if l.starts_with("warns ") {
                self.old_warns = (ModuleRecords::_num(l.subslice(6, l.size() - 6)) as u32)
            } else if l.starts_with("pthread ") {
                self.old_pthread = l == "pthread 1"
            } else if l == "errors 1" {
                self.old_errors = true
            }
        }

        self.plan_base = true
        if missed {
            return false
        }

        if self.old_errors {
            self.status = "miss: the recorded run had errors"
            return false
        }

        self.old_diag = tail
        self.hit      = true
        self.status   = f"hit, {nmods} modules"
        return true
    }

    /// \brief the plan record of every module the manifest names, as the
    ///        recorded run wrote them; false when one is missing or damaged
    ///        (then there is no plan: every module is re-checked). Read
    ///        before write() replaces them.
    pub fn load_plan(self, out: *cxx::std::vector<PlanModule>) -> bool {
        out->clear()
        for var l: string in self.old_mods {
            var tab  = ModuleRecords::_find(l, "\t")
            var name = if (tab == usize::MAX) => (l) else => l.subslice(0, tab)
            var text = ""
            if !LinkFS::read(self._plan_path(name), &text) {
                return false
            }

            var pm = PlanModule()
            if (!pm.parse(text)) || pm.name != name {
                return false
            }

            out->push_back(pm)
        }

        return !out->empty()
    }

    /// \brief a hit whose check rehashed a touched file writes the new
    ///        mtimes back, so the next hit is stat-only again.
    pub fn refresh(self) {
        if !self._refreshed {
            return
        }

        var body = ""
        for var l: string in self._lines {
            body += l + "\n"
        }

        self._publish(self._manifest, body + f"diag {self.old_diag.size()}\n" + self.old_diag + "\nend\n")
    }

    /// \brief the records of a run whose Sema ran: one per module first,
    ///        then the manifest, each through a private name and a rename,
    ///        so a crash leaves either the old set or the new one and never
    ///        a manifest naming records that are not there. A run with an
    ///        error writes them too, marked (`errors 1`): a baseline for the
    ///        next run's plan, never a hit.
    pub fn write(self) -> bool {
        if !LinkFS::make_dirs(self.dir) {
            return false
        }

        var m = f"kairo-incr-run {INCR_SEMA_SCHEMA}\n" + self._f_lines
        m += f"t {self._t_start}\n"
        m += self._file_line("exe", self._exe, "")

        // Every file the run opened, each once, by path order.
        var seen  = llvm::StringSet<llvm::MallocAllocator>()
        var all   = cxx::std::vector<string>()
        var all_h = cxx::std::vector<string>()
        for var i: usize = 0; i < self.src_files.size(); ++i {
            var p = self.src_files[i]
            if p.empty() || seen.contains(kairo::sref(p)) {
                continue
            }

            seen.insert(kairo::sref(p))
            all.push_back(p + "\t" + self.src_hash[i])
        }

        for var p: string in self.hdr_files {
            if p.empty() || seen.contains(kairo::sref(p)) {
                continue
            }

            seen.insert(kairo::sref(p))
            all.push_back(p + "\t")
        }

        llvm::sort(all.begin(), all.end())
        var dirs = llvm::StringSet<llvm::MallocAllocator>()
        var dir_list = cxx::std::vector<string>()
        for var e: string in all {
            var tab = ModuleRecords::_find(e, "\t")
            var p   = e.subslice(0, tab)
            var h   = e.subslice(tab + 1, e.size() - tab - 1)
            m += self._file_line("file", p, h)
            if p.ends_with(".k") {
                self._dirs_of(p, unsafe &dirs, unsafe &dir_list)
            }
        }

        llvm::sort(dir_list.begin(), dir_list.end())
        for var d: string in dir_list {
            m += "dir " + ModuleRecords::_listing(d) + " " + d + "\n"
        }

        for var o: string in self.objects {
            m += self._file_line("obj", o, "")
        }

        // Per-module records: what phase 3 needs (interface, rows, header
        // and object keys). The manifest names each with I(m) and its O
        // keys, which --incr-verify compares.
        var mods = cxx::std::vector<string>()
        for var i: usize = 0; i < self.mod_names.size(); ++i {
            var name = self.mod_names[i]
            var ks   = ""
            for var k: string in self.keys {
                if k.starts_with(name + "\t") {
                    ks += (if (ks.empty()) => ("") else => ",") + k.subslice(name.size() + 1, k.size() - name.size() - 1)
                }
            }

            if ks.empty() {
                ks = "-"
            }

            var rec = "{\"version\": 1, \"module\": " + ModuleRecords::_json(name) + ", \"objects\": " + ModuleRecords::_json(ks) + ",\n" + self.mod_json[i] + "}\n"
            var rp = self.dir + "/" + ObjectCache::hash(name) + ".json"
            if !self._publish(rp, rec) {
                return false
            }

            // The same facts as the lines the plan reads, and the module's
            // own diagnostics (Sema/Incremental/Plan.k).
            if i < self.mod_plan.size()
                && !self._publish(self._plan_path(name), self.mod_plan[i].render()) {
                return false
            }

            mods.push_back("mod " + name + "\t" + ks + "\t" + self.mod_hash[i])
        }

        llvm::sort(mods.begin(), mods.end())
        for var l: string in mods {
            m += l + "\n"
        }

        if self.errors {
            m += "errors 1\n"
        }

        m += "pthread " + (if (self.pthread) => ("1") else => "0") + "\n"
        m += f"warns {self.warns}\n"
        m += f"diag {self.diag.size()}\n" + self.diag + "\nend\n"
        return self._publish(self._manifest, m)
    }

    /// A plan record belongs to ONE manifest: another input, or the same
    /// input with another output, sharing the cache directory checks the
    /// same modules and must not replace the rows this manifest's next
    /// plan is evaluated over (it would diff against a run it never saw).
    priv fn _plan_path(self, const name: string) -> string {
        return self.dir + "/" + ObjectCache::hash(name + "\n" + self._manifest) + ".plan"
    }

    /// \brief the modules this run recorded, sorted: what verify compares
    ///        with old_mods.
    pub fn new_mods(self) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        for var i: usize = 0; i < self.mod_names.size(); ++i {
            var name = self.mod_names[i]
            var ks   = ""
            for var k: string in self.keys {
                if k.starts_with(name + "\t") {
                    ks += (if (ks.empty()) => ("") else => ",") + k.subslice(name.size() + 1, k.size() - name.size() - 1)
                }
            }

            if ks.empty() {
                ks = "-"
            }

            out.push_back(name + "\t" + ks + "\t" + self.mod_hash[i])
        }

        llvm::sort(out.begin(), out.end())
        return out
    }

    pub static fn same_list(a: *cxx::std::vector<string>, b: *cxx::std::vector<string>) -> bool {
        if a->size() != b->size() {
            return false
        }

        for var i: usize = 0; i < a->size(); ++i {
            if (*a)[i] != (*b)[i] {
                return false
            }
        }

        return true
    }

    /// `<kind> <mtime> <size> <hash> <path>`. A file whose mtime is not
    /// before the run started gets mtime 0, which check() never trusts: an
    /// edit made during the run, or in the same clock tick as the record,
    /// would otherwise keep the old stat and be a hit forever.
    priv fn _file_line(self, const kind: string, const p: string, const read_hash: string) -> string {
        var mt: u64 = 0
        var sz: u64 = 0
        if !ModuleRecords::_stat(p, &mt, &sz) {
            return kind + " 0 0 missing " + p + "\n"
        }

        var h = read_hash
        if h.empty() {
            h = ModuleRecords::_hash_file(p)
        }

        var slack: u64 = 2000000000 // 2 s, in ns: a coarse filesystem clock
        if mt + slack >= self._t_start {
            mt = 0
        }

        return kind + f" {mt} {sz} " + h + " " + p + "\n"
    }

    /// "" when the file of manifest line \p i is unchanged; else the reason.
    priv fn _check_file(self, i: usize) -> string {
        var l    = self._lines[i]
        var kind = ModuleRecords::_field(l, 0)
        var smt  = ModuleRecords::_num(ModuleRecords::_field(l, 1))
        var ssz  = ModuleRecords::_num(ModuleRecords::_field(l, 2))
        var sh   = ModuleRecords::_field(l, 3)
        var p    = ModuleRecords::_field_rest(l, 4)
        var what = "changed: "
        if kind == "exe" {
            what = "compiler changed: "
        } else if kind == "obj" {
            what = "object changed: "
        }

        // Another executable than the one that recorded: the stored line
        // describes that one, and its stat says nothing about this one.
        if kind == "exe" && p != self._exe {
            return "compiler changed: " + self._exe
        }

        var mt: u64 = 0
        var sz: u64 = 0
        var ok  = ModuleRecords::_stat(p, &mt, &sz)
        if sh == "missing" {
            if ok {
                return "added: " + p
            }

            return ""
        }

        if !ok {
            return (if (kind == "exe") => ("compiler changed: ") else => "removed: ") + p
        }

        if (!self.paranoid) && smt != 0 && smt == mt && ssz == sz {
            return ""
        }

        if sz != ssz {
            return what + p
        }

        if ModuleRecords::_hash_file(p) != sh {
            return what + p
        }

        // Same bytes, new stat: a touch. Written back by refresh().
        var slack: u64 = 2000000000
        if mt + slack < ModuleRecords::_now() && mt != smt {
            self._lines[i] = kind + f" {mt} {sz} " + sh + " " + p
            self._refreshed = true
        }

        return ""
    }

    /// The directories whose listing can change what an import of \p p
    /// resolves to: its own, and under every search root the same relative
    /// directory and each of its parents. A module file added at any of
    /// them can shadow, collide with or (foo.k beside foo/module.k) change
    /// a resolution with no source edited.
    priv fn _dirs_of(self,
                     const p:  string,
                     set:      unsafe *llvm::StringSet<llvm::MallocAllocator>,
                     list:     unsafe *cxx::std::vector<string>) {
        var own = LinkFS::parent(p)
        ModuleRecords::_add_dir(own, set, list)
        var best = ""
        for var r: string in self.roots {
            if p.size() > r.size() + 1 && p.starts_with(r + "/") && r.size() > best.size() {
                best = r
            }
        }

        if best.empty() {
            return
        }

        var rel  = p.subslice(best.size() + 1, p.size() - best.size() - 1)
        var segs = cxx::std::vector<string>()
        var cur  = ""
        for var i: usize = 0; i < rel.size(); ++i {
            if rel[i] == ('/' as u8) {
                segs.push_back(cur)
                cur = ""
            } else {
                cur += rel.subslice(i, 1)
            }
        }

        for var r: string in self.roots {
            var d = r
            ModuleRecords::_add_dir(d, set, list)
            for var s: string in segs {
                d = d + "/" + s
                ModuleRecords::_add_dir(d, set, list)
            }
        }
    }

    priv static fn _add_dir(const d:  string,
                            set:      unsafe *llvm::StringSet<llvm::MallocAllocator>,
                            list:     unsafe *cxx::std::vector<string>) {
        if d.empty() || set->contains(kairo::sref(d)) {
            return
        }

        set->insert(kairo::sref(d))
        list->push_back(d)
    }

    /// The hash of \p d's module-relevant entries: every `.k` file and
    /// every directory, sorted; "missing" when there is no such directory.
    /// Other files (an output binary written into the working directory)
    /// do not count, or every linking run would miss the next.
    priv static fn _listing(const d: string) -> string {
        if !LinkFS::is_dir(d) {
            return "missing"
        }

        var names = cxx::std::vector<string>()
        for var n: string in LinkFS::list_dir(d) {
            if n.ends_with(".k") {
                names.push_back(n)
            } else if LinkFS::is_dir(d + "/" + n) {
                names.push_back(n + "/")
            }
        }

        llvm::sort(names.begin(), names.end())
        var s = ""
        for var n: string in names {
            s += n + "\n"
        }

        return ObjectCache::hash(s)
    }

    /// Through a private name and a rename, as the object store writes.
    priv fn _publish(self, const path: string, const text: string) -> bool {
        self._seq += 1
        var tmp = f"{path}.{llvm::sys::Process::getProcessId()}-{self._seq}.tmp"
        if !LinkFS::write(tmp, text) {
            LinkFS::remove(tmp)
            return false
        }

        if !LinkFS::rename(tmp, path) {
            LinkFS::remove(tmp)
            return false
        }

        return true
    }

    priv static fn _hash_file(const p: string) -> string {
        var h = kairo::std::from_std_string<string>(kairo::objcache_file_hash(kairo::sref(p)))
        if h.empty() {
            return "missing"
        }

        return h
    }

    priv static fn _stat(const p: string, @inout mt: u64, @inout sz: u64) -> bool {
        var st: llvm::sys::fs::file_status
        var ec = llvm::sys::fs::status(llvm::Twine(kairo::sref(p)), &st, true)
        if ec.value() != 0 {
            return false
        }

        mt = st.getLastModificationTime().time_since_epoch().count() as u64
        sz = st.getSize() as u64
        return true
    }

    /// Now, on the clock LinkFS::mtime reads (the object store's gc compares
    /// the two the same way).
    priv static fn _now() -> u64 {
        return (cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
            cxx::std::chrono::system_clock::now().time_since_epoch(),
        ).count() as u64)
    }

    priv static fn _split(const s: string) -> cxx::std::vector<string> {
        var out          = cxx::std::vector<string>()
        var start: usize = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] == ('\n' as u8) {
                out.push_back(s.subslice(start, i - start))
                start = i + 1
            }
        }

        if start < s.size() {
            out.push_back(s.subslice(start, s.size() - start))
        }

        return out
    }

    /// Space-separated field \p k of \p l.
    priv static fn _field(const l: string, k: usize) -> string {
        var n: usize = 0
        var start: usize = 0
        for var i: usize = 0; i <= l.size(); ++i {
            if i == l.size() || l[i] == (' ' as u8) {
                if n == k {
                    return l.subslice(start, i - start)
                }

                n += 1
                start = i + 1
            }
        }

        return ""
    }

    /// Everything from field \p k on: a path may hold spaces.
    priv static fn _field_rest(const l: string, k: usize) -> string {
        var n: usize = 0
        for var i: usize = 0; i < l.size(); ++i {
            if n == k {
                return l.subslice(i, l.size() - i)
            }

            if l[i] == (' ' as u8) {
                n += 1
            }
        }

        return ""
    }

    priv static fn _num(const s: string) -> u64 {
        var n: u64 = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] < ('0' as u8) || s[i] > ('9' as u8) {
                break
            }

            n = n * 10 + ((s[i] - ('0' as u8)) as u64)
        }

        return n
    }

    priv static fn _find(const hay: string, const needle: string) -> usize {
        var n = hay.size()
        var m = needle.size()
        if m > n {
            return usize::MAX
        }

        for var i: usize = 0; i + m <= n; ++i {
            var j: usize = 0
            while j < m && hay[i + j] == needle[j] {
                j += 1
            }

            if j == m {
                return i
            }
        }

        return usize::MAX
    }

    priv static fn _json(const s: string) -> string {
        var out = "\x22"
        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i]
            if c == (34 as u8) || c == (92 as u8) {
                out += "\\"
            }

            out += s.subslice(i, 1)
        }

        return out + "\x22"
    }
}
