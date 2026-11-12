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
ffi "c++" import "chrono"

import API::FS::LinkFS
import Command::FlagTranslator::{
    ClangSpelling,
    FlagTranslator,
}
import Diagnostic::Registry::DiagID
import Driver::CompilerInstance::CompilerInstance
import Driver::FrontendAction::FrontendAction
import Location::SourceManager::FileID
import Resolution::ModulePath::ModulePath
import Support::FileIO::Path::Path
import Support::Tuning::{
    CACHE_ENTRY_MAX_AGE_NS,
    CACHE_PARTIAL_MAX_AGE_NS,
}
import std::env

extend CompilerInstance {
    /// # The runtime object cache

    /// \brief where _compile_runtime caches the runtime's objects:
    ///        <cache root>/rt (_cache_root), shared by every link of every
    ///        target and option set; "" when there is no cache root.
    prot fn _rt_cache_dir(self) -> string {
        if self._backend == &null {
            return ""
        }

        var root = CompilerInstance::_cache_root()
        if root.empty() {
            return ""
        }

        return root + "/rt"
    }

    /// `<path> <size> <mtime>` for one file, or `<path> -` when it cannot
    /// be stat'd (a file that appears later then changes the key too).
    priv static fn _rt_stamp(const p: string) -> string {
        var st: llvm::sys::fs::file_status
        var ec = llvm::sys::fs::status(llvm::Twine(kairo::sref(p)), &st, true)
        if ec.value() != 0 {
            return p + " -\n"
        }

        var size  = (st.getSize())
        var mtime = (st.getLastModificationTime().time_since_epoch().count() as u64)
        return f"{p} {size} {mtime}\n"
    }

    /// \brief every file a runtime object may be built from, stamped: the
    ///        compiler (clang is linked into it, and it stages the sysroot
    ///        and resource dir beside itself), every file directly in
    ///        <runtime root>/rt (sources and the headers they share), and
    ///        the vendored mimalloc (_runtime_deps: a submodule bump never
    ///        touches rt/mimalloc.c).
    ///
    /// \details One set for all of the runtime's objects, not each one's own
    ///          includes: any change rebuilds all of them, which costs only
    ///          the first link after it, and no include an object reads can
    ///          be left out of its key. Sorted, so the key does not follow
    ///          readdir.
    prot fn _rt_fingerprint(self) -> string {
        var out   = CompilerInstance::_rt_stamp(env::exe_path())
        var rroot = self._runtime_root()
        if rroot.empty() {
            return out
        }

        var rt    = Path::join_str(rroot, "rt")
        var files = cxx::std::vector<string>()
        for var name: string in LinkFS::list_dir(rt) {
            var p = rt + "/" + name
            if LinkFS::is_file(p) {
                files.push_back(p)
            }
        }

        llvm::sort(
            files.begin(),
            files.end(),
            fn (const a: string, const b: string) || -> bool = a < b,
        )

        for *p in files {
            out += CompilerInstance::_rt_stamp(*p)
        }

        for var p: string in self._runtime_deps() {
            out += CompilerInstance::_rt_stamp(p)
        }

        return out
    }

    /// \brief copies the cache entry \p entry to \p obj; false (compile it)
    ///        when there is none or it does not read as an object file.
    ///
    /// \details Entries are only ever renamed into place whole
    ///          (_rt_cache_store), so a partial write is never seen; the
    ///          parse guards against what else can damage a file in a cache
    ///          directory (a full disk, a crash of the file system, a hand
    ///          edit), which would otherwise fail the link instead of
    ///          rebuilding the object.
    prot static fn _rt_cache_fetch(const entry: string, const obj: string) -> bool {
        if !LinkFS::is_file(entry) {
            return false
        }

        {
            var o = llvm::object::ObjectFile::createObjectFile(kairo::sref(entry))
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

    /// \brief stores the object \p obj as the cache entry \p entry: copied to
    ///        a private name and renamed into place, so a parallel link reads
    ///        the whole object or none; two runs that both missed write the
    ///        same bytes and the last rename wins. Then the slot's older
    ///        entries (`<stem>-<slot>-*.o`, other inputs) are removed.
    ///
    /// \return true when the entry was written.
    prot static fn _rt_cache_store(const obj: string, const entry: string) -> bool {
        var tmp = f"{entry}.tmp-{llvm::sys::Process::getProcessId()}"
        var ec = llvm::sys::fs::copy_file(
            llvm::Twine(kairo::sref(obj)),
            llvm::Twine(kairo::sref(tmp)),
        )

        if ec.value() != 0 {
            LinkFS::remove(tmp)
            return false
        }

        if !LinkFS::rename(tmp, entry) {
            LinkFS::remove(tmp)
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
            if name[cut] == ('-' as u8) {
                found = true
                break
            }
        }

        if !found {
            return true
        }

        var prefix = string(unsafe ((name.raw() as unsafe *const u8) as *const u8), cut + 1)
        for var other: string in LinkFS::list_dir(dir) {
            if other == name || !other.starts_with(prefix) || !other.ends_with(".o") {
                continue
            }

            // Only <prefix><hash>.o; the slot hash already separates stems
            // that share a prefix, this is belt and braces.
            var rest = string(
                unsafe (((other.raw() as unsafe *const u8) + prefix.size()) as *const u8),
                other.size() - prefix.size(),
            )

            if !(cxx::std::string::npos == kairo::std::to_std_string(rest).find(r"-")) {
                continue
            }

            LinkFS::remove(dir + "/" + other)
        }

        return true
    }

    /// \brief removes the runtime cache's entries no store has refreshed for
    ///        30 days (a target or option set no longer used) and private
    ///        copies a crashed store left (a day old). Run after a store,
    ///        which is rare; a hit lists nothing.
    prot static fn _rt_cache_gc(const dir: string) {
        if dir.empty() {
            return
        }

        var now = (cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
            cxx::std::chrono::system_clock::now().time_since_epoch(),
        ).count() as u64)
        for var name: string in LinkFS::list_dir(dir) {
            var p = dir + "/" + name
            if !LinkFS::is_file(p) {
                continue
            }

            var partial = !(cxx::std::string::npos == kairo::std::to_std_string(name).find(
                r".tmp-",
            ))

            var last  = LinkFS::mtime(p)
            var limit = if (partial) => (CACHE_PARTIAL_MAX_AGE_NS) else => CACHE_ENTRY_MAX_AGE_NS
            if last != 0 && now > last && now - last > limit {
                LinkFS::remove(p)
            }
        }
    }

    /// # The Kairo library (--kairo-lib)

    /// \brief builtin, std and the runtime, as objects the link takes
    ///        lazily (_lib_lazy): what a link of objects from separate
    ///        `kcc -c` runs needs and none of those runs wrote.
    ///
    /// \details Cached per target and code generation options, under
    ///          the toolchain's cache root (_cache_root), and rebuilt when the compiler or any source
    ///          it was built from changes (the manifest records each one's
    ///          mtime). Built in THIS session, before the inputs, when the
    ///          cache has none: it claims builtin and std first (claim_fid),
    ///          so the inputs' actions emit no copy of their own, and the
    ///          link finds them here. Lazy, so a run that did emit its own
    ///          copy (a valid cache) keeps it, and an unused std module costs
    ///          nothing.
    prot fn _kairo_lib(self) -> bool {
        var dir = self._kairo_lib_dir()
        if dir.empty() { // no cache root: the run's own objects are all there is
            return true
        }

        if self._read_kairo_lib(dir) {
            return true
        }

        if !self._build_kairo_lib(dir) {
            self._diag->report(DiagID::L007E, f"cannot build the Kairo library in {dir}").emit()
            return false
        }

        if !self._read_kairo_lib(dir) {
            self._diag->report(DiagID::L007E, f"the Kairo library in {dir} is incomplete").emit()
            return false
        }

        return true
    }

    /// \brief the toolchain's cache root, shared by the Kairo library
    ///        (_kairo_lib_dir) and the runtime objects (_rt_cache_dir):
    ///        $KAIRO_CACHE_DIR, else $XDG_CACHE_HOME/kairo, else
    ///        ~/.cache/kairo, else %LOCALAPPDATA%/kairo (Windows, where HOME
    ///        is usually unset). "" when none is set: nothing is cached.
    prot static fn _cache_root() -> string {
        var root = LinkFS::env("KAIRO_CACHE_DIR")
        if root.empty() {
            var xdg = LinkFS::env("XDG_CACHE_HOME")
            if !xdg.empty() {
                root = xdg + "/kairo"
            }
        }

        if root.empty() {
            var home = LinkFS::env("HOME")
            if !home.empty() {
                root = home + "/.cache/kairo"
            }
        }

        if root.empty() {
            var local = LinkFS::env("LOCALAPPDATA")
            if !local.empty() {
                root = local + "/kairo"
            }
        }

        // One separator. Windows hands back C:\Users\... and the library code
        // compares paths the source manager spells with '/' against ones built
        // here: a mixed C:\...\Local/kairo/... root never matched, so the
        // library's own temporary entry was recorded as a source and the cache
        // was "incomplete" on every Windows run. Windows takes '/' everywhere.
        eval if defined!(_WIN32) {
            for var i: usize = 0; i < root.size(); ++i {
                if root[i] == ('\\' as u8) {
                    root[i] = ('/' as u8)
                }
            }
        }

        return root
    }

    /// The cache directory for this target and option set; "" without a root.
    priv fn _kairo_lib_dir(self) -> string {
        var root = CompilerInstance::_cache_root()
        if root.empty() || self._backend == &null {
            return ""
        }

        // What the objects' code depends on: the compiler, the target and
        // its ISA words, the code generation and optimization words, debug
        // info, and where builtin and std are read from. Not the inputs'
        // own -D/-I/warnings: they never reach the library.
        var key     = env::exe_path() + "\n" + self._backend->triple()
        var *inv    = self.invocation()
        var missing = cxx::std::vector<string>()
        for var w: string in FlagTranslator::target(&inv->target, ClangSpelling::Driver) {
            key += "\n" + w
        }

        for var w: string in FlagTranslator::codegen(&*inv, self._backend->triple(), ClangSpelling::Driver, unsafe &missing) {
            key += "\n" + w
        }

        var osz: i32 = 0
        if inv->codegen.opt_size_z {
            osz = 2
        } else if inv->codegen.opt_size {
            osz = 1
        }

        for var w: string in FlagTranslator::optimization(inv->codegen.opt_level, osz, inv->codegen.f_vectorize, ClangSpelling::Driver) {
            key += "\n" + w
        }

        key += f"\ndebug={FlagTranslator::debug_on(&inv->codegen)}"
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

    /// The library's objects from \p dir's manifest into _lib_lazy; false
    /// when there is none or a recorded source has changed.
    priv fn _read_kairo_lib(self, const dir: string) -> bool {
        var text = ""
        if !LinkFS::read(dir + "/manifest", &text) {
            return false
        }

        var objs          = cxx::std::vector<string>()
        var archive       = ""
        var start:  usize = 0
        for var i: usize = 0; i <= text.size(); ++i {
            if i < text.size() && text[i] != ('\n' as u8) {
                continue
            }

            var line = string(
                unsafe (((text.raw() as unsafe *const u8) + start) as *const u8),
                i - start,
            )

            start = i + 1
            if line.starts_with("obj ") {
                objs.push_back(
                    dir + "/" + string(
                        unsafe (((line.raw() as unsafe *const u8) + 4) as *const u8),
                        line.size() - 4,
                    ),
                )

                continue
            }

            if line.starts_with("ar ") {
                archive = dir + "/" + string(
                    unsafe (((line.raw() as unsafe *const u8) + 3) as *const u8),
                    line.size() - 3,
                )

                continue
            }

            if line.starts_with("src ") {
                // `src <mtime> <path>`: the path may hold spaces, the mtime not.
                var rest = string(
                    unsafe (((line.raw() as unsafe *const u8) + 4) as *const u8),
                    line.size() - 4,
                )

                var sp: usize = 0
                while sp < rest.size() && rest[sp] != (' ' as u8) {
                    sp += 1
                }

                if sp >= rest.size() {
                    return false
                }

                var want = string(unsafe ((rest.raw() as unsafe *const u8) as *const u8), sp)
                var path = string(
                    unsafe (((rest.raw() as unsafe *const u8) + sp + 1) as *const u8),
                    rest.size() - sp - 1,
                )

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

        if !archive.empty() && !LinkFS::is_file(archive) {
            return false
        }

        for *o in objs {
            self._lib_lazy.push_back(*o)
        }

        self._lib_archive = archive
        // Last use, for _gc_kairo_libs.
        LinkFS::write(dir + "/used", "")
        return objs.size() > 0
    }

    /// \brief builds the library into \p dir: a virtual entry that imports
    ///        std (so builtin and every std module are reached under their
    ///        own module paths), and the runtime, written to a private
    ///        directory and renamed into place, so parallel builds never see
    ///        half a library.
    priv fn _build_kairo_lib(self, const dir: string) -> bool {
        var tmp = f"{dir}.tmp-{llvm::sys::Process::getProcessId()}"
        LinkFS::remove_tree(tmp)
        if !LinkFS::make_dirs(tmp) {
            return false
        }

        var saved_dir  = self._obj_dir
        var saved_objs = self._native_objs.size()
        self._obj_dir = tmp
        finally {
            self._obj_dir = saved_dir
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
        if !LinkFS::write(tmp + "/kairo-lib.k", self._lib_text) {
            return false
        }

        var entry = Path(tmp + "/kairo-lib.k") // after the write: a Path stats on construction
        var unsafe *action = kairo::std::create<FrontendAction>(
            entry,
            ModulePath(),
            self._g_scope,
            self._imp,
            &self,
        )

        finally {
            kairo::std::destroy(action)
        }

        action->run()
        if action->result.had_fatal || self._diag->error_count() != errs {
            return false
        }

        var objs = action->result.objects

        if !self._compile_runtime() {
            return false
        }

        for var i: usize = saved_objs; i < self._native_objs.size(); ++i {
            objs.push_back(self._native_objs[i])
        }

        while self._native_objs.size() > saved_objs {
            self._native_objs.pop_back()
        }

        var man = ""
        // A MinGW link takes the library as an archive (LinkJob::lazy_archive).
        // Normalized first: kairo's spelling (x86_64-windows-gnu) has no
        // vendor, and llvm::Triple reads its second field as one.
        var norm = llvm::Triple::normalize(kairo::sref(self._backend->triple()))
        if llvm::Triple(llvm::Twine(norm)).isWindowsGNUEnvironment() {
            if !LinkFS::write_archive(tmp + "/libkairo.a", &objs) {
                return false
            }

            man += "ar libkairo.a\n"
        }

        for *o in objs {
            if !o->starts_with(tmp + "/") {
                return false
            }

            man += "obj " + string(
                unsafe (((o->raw() as unsafe *const u8) + tmp.size() + 1) as *const u8),
                o->size() - tmp.size() - 1,
            ) + "\n"
        }

        man += f"src {LinkFS::mtime(env::exe_path())} {env::exe_path()}\n"
        var n = self._sm->file_count()
        for var i: usize = 0; i < n; ++i {
            var p = self._sm->get_filename(i as FileID)
            // Virtual buffers (-D) have no file; the entry is in tmp, which
            // the rename below moves.
            if p.empty() || !LinkFS::is_file(p) || p.starts_with(tmp + "/") {
                continue
            }

            man += f"src {LinkFS::mtime(p)} {p}\n"
        }

        for var k: InputKind in self._runtime_sources() {
            man += f"src {LinkFS::mtime(k.path)} {k.path}\n"
        }

        for var p: string in self._runtime_deps() {
            man += f"src {LinkFS::mtime(p)} {p}\n"
        }

        if !LinkFS::write(tmp + "/manifest", man) {
            return false
        }

        // A library already there is stale (_kairo_lib read it and refused
        // it): moved aside first, since a rename cannot replace a full
        // directory. If a parallel build renames its fresh one in between,
        // this rename fails and theirs is used.
        if LinkFS::is_dir(dir) {
            var old = f"{dir}.stale-{llvm::sys::Process::getProcessId()}"
            if LinkFS::rename(dir, old) {
                LinkFS::remove_tree(old)
            }
        }

        if LinkFS::rename(tmp, dir) {
            built = true
            self._gc_kairo_libs(dir)
            return true
        }

        // Windows refuses to rename a directory while a file in it is open or
        // mapped, and this session still maps tmp/kairo-lib.k (the source it just
        // compiled): kcc on Windows failed every first build here. A copy has no
        // open files, so it renames into place as atomically as tmp would have;
        // tmp is left to _gc_kairo_libs / the next run (its .tmp- name ages out).
        if !LinkFS::is_dir(dir) {
            var copy = f"{dir}.copy-{llvm::sys::Process::getProcessId()}"
            LinkFS::remove_tree(copy)
            if LinkFS::copy_tree(tmp, copy) && LinkFS::rename(copy, dir) {
                self._gc_kairo_libs(dir)
                return true
            }

            LinkFS::remove_tree(copy)
        }

        // Another build got there first: theirs is as good as this one.
        return LinkFS::is_dir(dir)
    }

    /// \brief removes the cached libraries beside \p keep that no link has
    ///        used for 30 days, and what a crashed build left (a day old).
    ///
    /// \details Every compiler rebuild and every option set leaves a library
    ///          of its own, and nothing else removes them. Run when a library
    ///          is built, which is rare; a link only touches `used`
    ///          (_read_kairo_lib).
    priv fn _gc_kairo_libs(self, const keep: string) {
        var root = LinkFS::parent(keep)
        var now = (cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
            cxx::std::chrono::system_clock::now().time_since_epoch(),
        ).count() as u64)
        for var name: string in LinkFS::list_dir(root) {
            var p = root + "/" + name
            if p == keep || !LinkFS::is_dir(p) {
                continue
            }

            var partial = !(cxx::std::string::npos == kairo::std::to_std_string(name).find(
                r".tmp-",
            ))
                || !(cxx::std::string::npos == kairo::std::to_std_string(name).find(r".stale-"))
            var last = LinkFS::mtime(p + "/used")
            if last == 0 {
                last = LinkFS::mtime(p + "/manifest")
            }

            if last == 0 {
                last = LinkFS::mtime(p)
            }

            var limit = if (partial) => (CACHE_PARTIAL_MAX_AGE_NS) else => CACHE_ENTRY_MAX_AGE_NS
            if last != 0 && now > last && now - last > limit {
                LinkFS::remove_tree(p)
            }
        }
    }
}
