/// --- The Kairo Project ----------------------- Driver/CompilerCache.k --- ///
///
///   CompilerInstance, part: the toolchain caches. The runtime object
///   cache (_compile_runtime's entries, keyed by the exact cc1 line and
///   inputs) and the Kairo library (--kairo-lib: builtin, std and the
///   runtime as lazily linked objects, built once per target and options).
///   An `extend` of the class in CompilerInstance.k (Driver/module.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/Object/ObjectFile.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "llvm/ADT/StringExtras.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "string"

import API::EnvNames::cache_root
import API::FS::LinkFS
import Command::FlagTranslator::{
    ClangSpelling,
    FlagTranslator,
}
import Config::ResourceLayout::ResourceLayout
import Diagnostic::Registry::DiagID
import Driver::CompilerInstance::CompilerInstance
import Driver::CompilerNative
import Driver::FrontendAction::FrontendAction
import Driver::ObjectCache::{
    CacheEntryStat,
    cache_evict_to_cap,
}
import Location::SourceManager::FileID
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Support::Ascii::find
import Support::FileIO::AtomicFile::{
    file_stat,
    is_leftover_temp,
    lock_file_drop,
    lock_file_take,
    now_ns,
    publish_copy,
}
import Support::FileIO::Path::Path
import Support::Tuning::{
    CACHE_ENTRY_MAX_AGE_NS,
    CACHE_LIBRARY_MAX_BYTES,
    CACHE_PARTIAL_MAX_AGE_NS,
    PUBLISH_LOCK_STALE_NS,
    PUBLISH_LOCK_WAIT_NS,
}
import std::env

/// How _publish_kairo_lib ended.
enum LibPublish {
    Nothing, ///< nothing published; a library may still be there (another build's)
    Theirs,  ///< a valid library was already there, and is used
    Renamed, ///< this build's library was renamed into place
    Copied,  ///< this build's library was copied into place (Windows)
}

extend CompilerInstance {
    /// # The runtime object cache

    /// where _compile_runtime caches the runtime's objects:
    /// <cache root>/rt (_cache_root), shared by every link of every
    /// target and option set; "" when there is no cache root.
    prot fn _rt_cache_dir(self) -> string {
        if self._backend == &null {
            return ""
        }

        var root = CompilerInstance::_cache_root()
        if root.is_empty() {
            return ""
        }

        return root + "/rt"
    }

    /// `<path> <size> <mtime>` for one file, or `<path> -` when it cannot
    /// be stat'd (a file that appears later then changes the key too).
    priv static fn _rt_stamp(const p: string) -> string {
        var mtime: u64 = 0
        var size:  u64 = 0
        if !file_stat(p, &mtime, &size) {
            return p.copy() + " -\n"
        }

        return f"{p} {size} {mtime}\n"
    }

    /// every file a runtime object may be built from, stamped: the
    /// compiler (clang is linked into it, and it stages the sysroot
    /// and resource dir beside itself), every file directly in
    /// <runtime root>/rt (sources and the headers they share), and
    /// the vendored mimalloc (_runtime_deps: a submodule bump never
    /// touches rt/mimalloc.c).
    ///
    /// One set for all of the runtime's objects, not each one's own
    /// includes: any change rebuilds all of them, which costs only
    /// the first link after it, and no include an object reads can
    /// be left out of its key. Sorted, so the key does not follow
    /// readdir.
    prot fn _rt_fingerprint(self) -> string {
        var out   = CompilerInstance::_rt_stamp(env::exe_path())
        var rroot = self._runtime_root()
        if rroot.is_empty() {
            return out
        }

        var rt              = Path::join_str(rroot, ResourceLayout::rt_subdir())
        var files: [string]
        for *name in LinkFS::list_dir(rt) {
            var p = rt.copy() + "/" + *name
            if LinkFS::is_file(p) {
                files.push(p)
            }
        }

        files.sort()

        for *p in files {
            out += CompilerInstance::_rt_stamp(*p)
        }

        for *p in self._runtime_deps() {
            out += CompilerInstance::_rt_stamp(*p)
        }

        return out
    }

    /// copies the cache entry `entry` to `obj`; false (compile it)
    /// when there is none or it does not read as an object file.
    ///
    /// Entries are only ever renamed into place whole
    /// (_rt_cache_store), so a partial write is never seen; the
    /// parse guards against what else can damage a file in a cache
    /// directory (a full disk, a crash of the file system, a hand
    /// edit), which would otherwise fail the link instead of
    /// rebuilding the object.
    prot static fn _rt_cache_fetch(const entry: string, const obj: string) -> bool {
        if !LinkFS::is_file(entry) {
            return false
        }

        {
            var o = llvm::object::ObjectFile::createObjectFile(
                kairo::sref(entry),
            )

            if !(o as bool) {
                llvm::consumeError(o.takeError())
                return false
            }
        }

        var ec = llvm::sys::fs::copy_file(
            llvm::Twine(kairo::sref(entry)),
            llvm::Twine(kairo::sref(obj)),
        )

        if ec.value() != 0 {
            LinkFS::remove(obj)
            return false
        }

        return true
    }

    /// stores the object `obj` as the cache entry `entry`: copied to
    /// a private name and renamed into place, so a parallel link reads
    /// the whole object or none; two runs that both missed write the
    /// same bytes and the last rename wins. Then the slot's older
    /// entries (`<stem>-<slot>-*.o`, other inputs) are removed.
    ///
    /// ### Returns
    /// true when the entry was written.
    prot static fn _rt_cache_store(const obj: string, const entry: string) -> bool {
        if !publish_copy(obj, entry) {
            return false
        }

        var dir  = LinkFS::parent(entry)
        var name = LinkFS::filename(entry)
        // Through the last '-': <stem>-<slot>-. A stem may itself hold
        // '-', the two hashes never do.
        var cut   = name.size()
        var found = false
        while cut > 0 {
            cut -= 1
            if name.data()[cut] == ('-' as u8) {
                found = true
                break
            }
        }

        if !found {
            return true
        }

        var prefix = name.subslice(0, cut + 1)

        for *other in LinkFS::list_dir(dir) {
            if *other == name || !other->starts_with(prefix) || !other->ends_with(".o") {
                continue
            }

            // Only <prefix><hash>.o; the slot hash already separates stems
            // that share a prefix, this is belt and braces.
            var rest = other->subslice(
                prefix.size(),
                other->size() - prefix.size(),
            )

            if find(rest, "-", 0) != usize::MAX {
                continue
            }

            LinkFS::remove(dir.copy() + "/" + *other)
        }

        return true
    }

    /// removes the runtime cache's entries no store has refreshed for
    /// 30 days (a target or option set no longer used) and private
    /// copies a crashed store left (a day old); then, past
    /// CACHE_LIBRARY_MAX_BYTES, the oldest-stored entries other than
    /// `used` (what this run fetched or stored), as the object cache
    /// does (cache_evict_to_cap). Run after a store, which is
    /// rare; a hit lists nothing.
    prot static fn _rt_cache_gc(const dir: string, const used: [string]) {
        if dir.is_empty() {
            return
        }

        var now                     = now_ns()
        var kept:  [CacheEntryStat]
        var total: u64              = 0
        for *name in LinkFS::list_dir(dir) {
            var p = dir.copy() + "/" + *name
            if !LinkFS::is_file(p) {
                continue
            }

            // A publish lock left by a crashed build (lock_file_take takes
            // over such a lock for its own entry; this removes the rest).
            if name->ends_with(".lock") && !LinkFS::is_dir(p) {
                var lm: u64 = 0
                var ls: u64 = 0
                if file_stat(p, &lm, &ls) && now > lm && now - lm > PUBLISH_LOCK_STALE_NS {
                    Path::remove_file(p)
                }

                continue
            }

            var partial = is_leftover_temp(*name)
            var last    = LinkFS::mtime(p)
            var limit   = if (partial) => (CACHE_PARTIAL_MAX_AGE_NS) else => CACHE_ENTRY_MAX_AGE_NS
            if last != 0 && now > last && now - last > limit {
                LinkFS::remove(p)
                continue
            }

            if !partial {
                var pinned = false
                for var i: usize = 0; i < used.size(); ++i {
                    if used[i] == p {
                        pinned = true
                        break
                    }
                }

                var bytes = LinkFS::size(p)
                kept.push(
                    CacheEntryStat { path: p.copy(), at: last, bytes: bytes, pinned: pinned },
                )

                total += bytes
            }
        }

        cache_evict_to_cap(&kept, total, CACHE_LIBRARY_MAX_BYTES, now)
    }

    /// # The Kairo library (--kairo-lib)

    /// builtin, std and the runtime, as objects the link takes
    /// lazily (_lib_lazy): what a link of objects from separate
    /// `kcc -c` runs needs and none of those runs wrote.
    ///
    /// Cached per target and code generation options, under
    /// the toolchain's cache root (_cache_root), and rebuilt when the compiler or any source
    /// it was built from changes (the manifest records each one's
    /// mtime). Built in THIS session, before the inputs, when the
    /// cache has none: it claims builtin and std first (claim_fid),
    /// so the inputs' actions emit no copy of their own, and the
    /// link finds them here. Lazy, so a run that did emit its own
    /// copy (a valid cache) keeps it, and an unused std module costs
    /// nothing.
    prot fn _kairo_lib(self) -> bool {
        var dir = self._kairo_lib_dir()
        if dir.is_empty() { // no cache root: the run's own objects are all there is
            return true
        }

        if self._read_kairo_lib(dir) {
            return true
        }

        if !self._build_kairo_lib(dir) {
            self._diag->report(
                DiagID::L007E,
                f"cannot build the Kairo library in {dir}",
            ).emit()
            return false
        }

        if !self._read_kairo_lib(dir) {
            self._diag->report(
                DiagID::L007E,
                f"the Kairo library in {dir} is incomplete",
            ).emit()
            return false
        }

        return true
    }

    /// the toolchain's cache root (API/EnvNames.k), shared by the
    /// Kairo library (_kairo_lib_dir), the runtime objects
    /// (_rt_cache_dir) and the LTO cache. "" when no variable names
    /// one: nothing is cached.
    prot static fn _cache_root() -> string {
        return cache_root()
    }

    /// The cache directory for this target and option set; "" without a root.
    priv fn _kairo_lib_dir(self) -> string {
        var root = CompilerInstance::_cache_root()
        if root.is_empty() || self._backend == &null {
            return ""
        }

        // What the objects' code depends on: the compiler, the target and
        // its ISA words, the code generation and optimization words, debug
        // info, and where builtin and std are read from. Not the inputs'
        // own -D/-I/warnings: they never reach the library.
        var key     = env::exe_path() + "\n" + self._backend->triple()
        var *inv    = self.invocation()
        var missing = cxx::std::vector<string>()
        for *w in FlagTranslator::target(&inv->target, ClangSpelling::Driver) {
            key += "\n" + *w
        }

        // --march is no word of target() or codegen() (it rides the driver
        // probe), and the library's objects are compiled for it: a link for
        // the baseline CPU must not take a library built for x86-64-v3.
        // host_cpu is what the host CPU default resolved to, features
        // included, which no word spells.
        for *w in FlagTranslator::march_driver(&inv->target) {
            key += "\n" + *w
        }

        key += "\nhost-cpu " + inv->target.host_cpu

        for *w in FlagTranslator::codegen(&*inv, self._backend->triple(), ClangSpelling::Driver, unsafe &missing) {
            key += "\n" + *w
        }

        var osz: i32 = 0
        if inv->codegen.opt_size_z {
            osz = 2
        } else if inv->codegen.opt_size {
            osz = 1
        }

        for *w in FlagTranslator::optimization(inv->codegen.opt_level, osz, inv->codegen.f_vectorize, ClangSpelling::Driver) {
            key += "\n" + *w
        }

        key += f"\ndebug={FlagTranslator::debug_on(&inv->codegen)}"
        // Kairo's own passes are registered with the pipeline, not spelled
        // as cc1 words, so one turned off is named here.
        for *name in inv->codegen.kairo_pass_off {
            key += "\nkairo-pass off " + *name
        }

        key += "\n" + self.invocation()->pp.builtins_dir + "\n" + self.invocation()->pp.std_dir
        // The one macro that does reach the library: the builtin's Global is
        // System inlined, or the kairo_global_* symbols (_settle_global_allocator).
        if self.invocation()->pp.global_allocator_set {
            key += "\nglobal-allocator-set"
        }

        var h   = llvm::xxh3_64bits(kairo::sref(key))
        var hex = llvm::utohexstr(h)
        return root + "/lib/" + self._backend->triple() + "-" + kairo::std::from_std_string<string>(
            hex,
        )
    }

    /// The library's objects from `dir`'s manifest into _lib_lazy; false
    /// when there is none or a recorded source has changed.
    priv fn _read_kairo_lib(self, const dir: string) -> bool {
        var objs:   [string]
        var archive          = ""
        if !CompilerInstance::_check_kairo_lib(dir, &objs, &archive) {
            return false
        }

        for *o in objs {
            self._lib_lazy.push(o->copy())
        }

        self._lib_archive = archive.copy()
        // Last use, for _gc_kairo_libs.
        LinkFS::write(dir.copy() + "/used", "")
        return true
    }

    /// The objects and the archive `dir`'s manifest names, into `objs`
    /// and `archive`; false when there is no manifest, it names no object,
    /// a recorded source has changed or a named file is missing. Reads
    /// only: _build_kairo_lib asks it too, of a library another build may
    /// have just published.
    priv static fn _check_kairo_lib(const dir:      string,
                                    @inout objs:    [string],
                                    @inout archive: string) -> bool {
        var text = ""
        if !LinkFS::read(dir.copy() + "/manifest", &text) {
            return false
        }

        var start: usize = 0
        for var i: usize = 0; i <= text.size(); ++i {
            if i < text.size() && text.data()[i] != ('\n' as u8) {
                continue
            }

            var line = text.subslice(start, i - start)
            start = i + 1
            if line.starts_with("obj ") {
                objs.push(dir.copy() + "/" + line.subslice(4, line.size() - 4))

                continue
            }

            if line.starts_with("ar ") {
                archive = dir.copy() + "/" + line.subslice(3, line.size() - 3)
                continue
            }

            if line.starts_with("src ") {
                // `src <mtime> <path>`: the path may hold spaces, the mtime not.
                var rest       = line.subslice(4, line.size() - 4)
                var sp:  usize = 0
                while sp < rest.size() && rest.data()[sp] != (' ' as u8) {
                    sp += 1
                }

                if sp >= rest.size() {
                    return false
                }

                var want = rest.subslice(0, sp)
                var path = rest.subslice(sp + 1, rest.size() - sp - 1)

                if f"{LinkFS::mtime(path)}" != want {
                    return false
                }
            }
        }

        for *o in objs {
            if !LinkFS::is_file(*o) {
                return false
            }
        }

        if !archive.is_empty() && !LinkFS::is_file(archive) {
            return false
        }

        return objs.size() > 0
    }

    /// builds the library into `dir`: a virtual entry that imports
    /// std (so builtin and every std module are reached under their
    /// own module paths), and the runtime, written to a private
    /// directory and renamed into place, so parallel builds never see
    /// half a library.
    priv fn _build_kairo_lib(self, const dir: string) -> bool {
        var tmp = f"{dir}.tmp-{llvm::sys::Process::getProcessId()}"
        LinkFS::remove_tree(tmp)
        if !LinkFS::make_dirs(tmp) {
            return false
        }

        var saved_dir  = self._obj_dir.copy()
        var saved_objs = self._native_objs.size()
        self._obj_dir = tmp.copy()
        finally {
            self._obj_dir = saved_dir.copy()
        }

        var built = false
        finally {
            if !built {
                LinkFS::remove_tree(tmp)
            }
        }

        var errs = self._diag->error_count()
        // A real file in the private directory: an action loads its input by
        // path, and a virtual buffer is not found that way.
        if !LinkFS::write(tmp.copy() + "/kairo-lib.k", self._lib_text) {
            return false
        }

        var entry = Path(tmp.copy() + "/kairo-lib.k") // after the write: a Path stats on construction
        var unsafe *action = unsafe (@create FrontendAction(
            entry,
            ModulePath(),
            unsafe &*self._g_scope,
            unsafe (self._imp as *ImportResolver),
            unsafe &self,
        ) as unsafe *FrontendAction)

        finally {
            @destroy unsafe (action as *FrontendAction)
        }

        action->run()
        if action->result.had_fatal || self._diag->error_count() != errs {
            return false
        }

        var objs = cxx::std::vector<string>()
        for *o in action->result.objects {
            objs.push_back(o->copy())
        }

        if !self._compile_runtime() {
            return false
        }

        for var i: usize = saved_objs; i < self._native_objs.size(); ++i {
            objs.push_back(self._native_objs[i].copy())
        }

        while self._native_objs.size() > saved_objs {
            self._native_objs.pop()
        }

        var man = ""
        // A MinGW link takes the library as an archive (LinkJob::lazy_archive).
        // Normalized first: kairo's spelling (x86_64-windows-gnu) has no
        // vendor, and llvm::Triple reads its second field as one.
        var norm = llvm::Triple::normalize(kairo::sref(self._backend->triple()))
        if llvm::Triple(llvm::Twine(norm)).isWindowsGNUEnvironment() {
            if !LinkFS::write_archive(tmp.copy() + "/libkairo.a", &objs) {
                return false
            }

            man += "ar libkairo.a\n"
        }

        for *o in objs {
            if !o->starts_with(tmp.copy() + "/") {
                return false
            }

            man += "obj " + o->subslice(
                tmp.size() + 1,
                o->size() - tmp.size() - 1,
            ) + "\n"
        }

        man += f"src {LinkFS::mtime(env::exe_path())} {env::exe_path()}\n"
        var n = self._sm->file_count()
        for var i: usize = 0; i < n; ++i {
            var p = self._sm->get_filename(i as FileID)
            // Virtual buffers (-D) have no file; the entry is in tmp, which
            // the rename below moves.
            if p.is_empty() || !LinkFS::is_file(p) || p.starts_with(tmp.copy() + "/") {
                continue
            }

            man += f"src {LinkFS::mtime(p)} {p}\n"
        }

        for *k in self._runtime_sources() {
            man += f"src {LinkFS::mtime(k->path)} {k->path}\n"
        }

        for *p in self._runtime_deps() {
            man += f"src {LinkFS::mtime(*p)} {*p}\n"
        }

        if !LinkFS::write(tmp.copy() + "/manifest", man) {
            return false
        }

        // The check and the rename run under `<dir>.lock`, so two builds
        // that both missed publish one at a time: the second sees the
        // first's library in its check and uses it. A lock not had in time
        // (lock_file_take's bound) leaves the publish unlocked, where a
        // rename that loses the race still fails safe (below). The lock is
        // dropped before the slow parts, removing a stale tree and the gc.
        var lock = dir.copy() + ".lock"
        var locked = lock_file_take(
            lock,
            PUBLISH_LOCK_STALE_NS,
            PUBLISH_LOCK_WAIT_NS,
        )

        var aside = ""
        var how   = self._publish_kairo_lib(dir, tmp, &aside)
        if locked {
            lock_file_drop(lock)
        }

        if !aside.is_empty() {
            LinkFS::remove_tree(aside)
        }

        if how == LibPublish::Renamed {
            built = true
        }

        if how == LibPublish::Renamed || how == LibPublish::Copied {
            self._gc_kairo_libs(dir)
            return true
        }

        if how == LibPublish::Theirs {
            return true
        }

        // Another build got there first: theirs is as good as this one.
        return LinkFS::is_dir(dir)
    }

    /// Moves the library built in `tmp` into `dir`; the caller holds
    /// `dir`'s lock when it could take it.
    ///
    /// A library already there was stale when _kairo_lib read it, and is
    /// moved aside to `aside` (the caller removes it), since a rename
    /// cannot replace a full directory. It is checked again first: a
    /// parallel build that missed too may have published its fresh library
    /// during this build, and moving that one aside would pull it from
    /// under that build's own read of it. Then theirs is used and this one
    /// is dropped. If a parallel build renames its fresh one in after the
    /// check, the rename fails and theirs is used.
    priv fn _publish_kairo_lib(self,
                               const dir:    string,
                               const tmp:    string,
                               @inout aside: string) -> LibPublish {
        if LinkFS::is_dir(dir) {
            var their_objs:   [string]
            var their_archive          = ""
            if CompilerInstance::_check_kairo_lib(
                dir,
                &their_objs,
                &their_archive,
            ) {
                return LibPublish::Theirs
            }

            var old = f"{dir}.stale-{llvm::sys::Process::getProcessId()}"
            if LinkFS::rename(dir, old) {
                aside = old.copy()
            }
        }

        if LinkFS::rename(tmp, dir) {
            return LibPublish::Renamed
        }

        // Windows refuses to rename a directory while a file in it is open or
        // mapped, and this session still maps tmp/kairo-lib.k (the source it just
        // compiled): kcc on Windows failed every first build here. A copy has no
        // open files, so it renames into place as atomically as tmp would have.
        if !LinkFS::is_dir(dir) {
            var copy = f"{dir}.copy-{llvm::sys::Process::getProcessId()}"
            LinkFS::remove_tree(copy)
            if LinkFS::copy_tree(tmp, copy) && LinkFS::rename(copy, dir) {
                return LibPublish::Copied
            }

            LinkFS::remove_tree(copy)
        }

        return LibPublish::Nothing
    }

    /// removes the cached libraries beside `keep` that no link has
    /// used for 30 days, and what a crashed build left (a day old);
    /// then, past CACHE_LIBRARY_MAX_BYTES, the least recently used
    /// others (cache_evict_to_cap).
    ///
    /// Every compiler rebuild and every option set leaves a library
    /// of its own, and nothing else removes them. Run when a library
    /// is built, which is rare; a link only touches `used`
    /// (_read_kairo_lib). `keep`, the one this run built, is never
    /// removed.
    priv fn _gc_kairo_libs(self, const keep: string) {
        var root                    = LinkFS::parent(keep)
        var now                     = now_ns()
        var kept:  [CacheEntryStat]
        var total: u64              = LinkFS::tree_size(keep)
        for *name in LinkFS::list_dir(root) {
            var p = root.copy() + "/" + *name
            if p == keep || !LinkFS::is_dir(p) {
                continue
            }

            // A publish lock left by a crashed build (lock_file_take takes
            // over such a lock for its own entry; this removes the rest).
            if name->ends_with(".lock") && !LinkFS::is_dir(p) {
                var lm: u64 = 0
                var ls: u64 = 0
                if file_stat(p, &lm, &ls) && now > lm && now - lm > PUBLISH_LOCK_STALE_NS {
                    Path::remove_file(p)
                }

                continue
            }

            var partial = is_leftover_temp(*name)

            var last = LinkFS::mtime(p.copy() + "/used")
            if last == 0 {
                last = LinkFS::mtime(p.copy() + "/manifest")
            }

            if last == 0 {
                last = LinkFS::mtime(p)
            }

            var limit = if (partial) => (CACHE_PARTIAL_MAX_AGE_NS) else => CACHE_ENTRY_MAX_AGE_NS
            if last != 0 && now > last && now - last > limit {
                LinkFS::remove_tree(p)
                continue
            }

            if !partial {
                var bytes = LinkFS::tree_size(p)
                kept.push(
                    CacheEntryStat { path: p.copy(), at: last, bytes: bytes, tree: true },
                )

                total += bytes
            }
        }

        cache_evict_to_cap(&kept, total, CACHE_LIBRARY_MAX_BYTES, now)
    }
}
