/// --- The Kairo Project -------------------------------- Sysroot/Cache.k --- ///
///
///   The sysroot cache (SysRoot.md 4.11):
///
///     <root>/stage/<stage>-<key>/     one dir per stage key, `.ok` inside
///     <root>/stage/<stage>-<key>.tmp  being written; renamed on success
///     <root>/stage/<stage>-<key>.failed  a failed stage: log/; retried
///     <root>/sysroots/<key>/          finished sysroots
///     <root>/by-name/<name>           -> ../sysroots/<key>
///     <root>/locks/<key>.lock         flock: concurrent builds of one key wait
///     <root>/verify/<sha(dir)>        tree_sha256 verification memo
///     <root>/build-id                 compiler_build_id memo
///
///   Root: $KAIRO_SYSROOT_CACHE, else <toolchain cache root>/sysroot with the
///   toolchain cache root as Driver.md defines it ($KAIRO_CACHE_DIR,
///   $XDG_CACHE_HOME/kairo, ~/.cache/kairo, %LOCALAPPDATA%/kairo).
///
///   by-name entries are symlinks, rewritten atomically (a new link renamed
///   over the old). Where a symlink cannot be made (Windows without the
///   privilege: llvm's create_link makes a hard link there, which a
///   directory cannot have) the entry is a one-line file holding the key,
///   and lookup reads either form.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "algorithm"
ffi "c++" import "vector"

import API::EnvNames::{
    EnvNames,
    cache_root,
}
import API::FS::LinkFS
import API::Text::LinkText

/// An exclusive lock on a file, held until the object is destroyed. Blocks:
/// a second ensure of the same key waits for the first and then finds its
/// result instead of building it again.
pub class SysLock {
    priv var _fd: i32 = -1

    pub fn SysLock(self) {
        self._fd = -1
    }

    /// False if the lock file cannot be opened or locked.
    pub fn acquire(self, const path: string) -> bool {
        LinkFS::make_dirs(LinkFS::parent(path))
        var fd: i32 = -1
        var ec = llvm::sys::fs::openFileForReadWrite(
            llvm::Twine(kairo::sref(path)),
            &fd,
            llvm::sys::fs::CD_OpenAlways,
            llvm::sys::fs::OF_None,
        )

        if ec.value() != 0 {
            return false
        }

        var lec = llvm::sys::fs::lockFile(fd)
        if lec.value() != 0 {
            llvm::sys::Process::SafelyCloseFileDescriptor(fd)
            return false
        }

        self._fd = fd
        return true
    }

    pub fn release(self) {
        if self._fd < 0 {
            return
        }

        llvm::sys::fs::unlockFile(self._fd)
        llvm::sys::Process::SafelyCloseFileDescriptor(self._fd)
        self._fd = -1
    }

    fn op finally(self) {
        self.release()
    }
}

pub class SysCache {
    pub var root: string

    pub fn SysCache(self, const root: string) {
        self.root = LinkText::strip_slash(root)
    }

    /// The `schema` field of every key object (Compiler/Spec/SysRoot.md
    /// section 7), written by both key builders (Generator's _key_json,
    /// Sdk's _key and the MSVC tools key): a bump re-keys every root.
    pub static fn key_schema() -> string {
        return "1"
    }

    pub static fn default_root() -> string {
        var r = LinkFS::env(EnvNames::kairo_sysroot_cache())
        if !r.empty() {
            return SysCache::_slashes(LinkText::strip_slash(r))
        }

        r = cache_root()
        if r.empty() {
            return ""
        }

        return SysCache::_slashes(r + "/sysroot")
    }

    pub fn stage_dir(self, const stage: string, const key: string) -> string {
        return f"{self.root}/stage/{stage}-{key}"
    }

    pub fn sysroot_dir(self, const key: string) -> string {
        return f"{self.root}/sysroots/{key}"
    }

    pub fn lock_path(self, const key: string) -> string {
        return f"{self.root}/locks/{key}.lock"
    }

    /// The finished sysroot \p name points at; "" when there is none (or
    /// the entry dangles: its key was removed by gc or rm).
    pub fn lookup(self, const name: string) -> string {
        var entry = f"{self.root}/by-name/{name}"
        if LinkFS::is_dir(entry) {
            return LinkFS::real(entry)
        }

        if LinkFS::is_file(entry) {
            var key = ""
            LinkFS::read(entry, &key)
            var dir = self.sysroot_dir(LinkText::trim(key))
            if LinkFS::is_dir(dir) {
                return dir
            }
        }

        return ""
    }

    /// The key by-name/\p name points at; "" for none.
    pub fn key_of(self, const name: string) -> string {
        var dir = self.lookup(name)
        if dir.empty() {
            return ""
        }

        return LinkFS::filename(dir)
    }

    /// Points by-name/\p name at sysroots/\p key, replacing any old entry in
    /// one rename so a concurrent lookup sees the old root or the new one.
    pub fn publish(self, const name: string, const key: string) -> bool {
        var dir = f"{self.root}/by-name"
        if !LinkFS::make_dirs(dir) {
            return false
        }

        var tmp = f"{dir}/.{name}.tmp-{llvm::sys::Process::getProcessId()}"
        LinkFS::remove(tmp)
        // Named, not a temporary: a Twine over a StringRef over an f-string
        // temporary dangled before create_link read it.
        var target = f"../sysroots/{key}"
        var ec = llvm::sys::fs::create_link(
            llvm::Twine(kairo::sref(target)),
            llvm::Twine(kairo::sref(tmp)),
        )

        if ec.value() != 0 || !LinkFS::is_dir(tmp) {
            LinkFS::remove(tmp)
            if !LinkFS::write(tmp, key + "\n") {
                return false
            }
        }

        if !LinkFS::rename(tmp, f"{dir}/{name}") {
            LinkFS::remove(tmp)
            return false
        }

        return true
    }

    /// `name -> key` lines, sorted by name.
    pub fn list(self) -> cxx::std::vector<string> {
        var names = LinkFS::list_dir(f"{self.root}/by-name")
        cxx::std::sort(names.begin(), names.end())
        var out = cxx::std::vector<string>()
        for var n: string in names {
            if LinkText::starts_with(n, ".") {
                continue
            }

            var key = self.key_of(n)
            if key.empty() {
                out.push_back(f"{n}  (dangling)")
            } else {
                out.push_back(f"{n}  {self.sysroot_dir(key)}")
            }
        }

        return out
    }

    /// Removes by-name/\p name, and its sysroot when no other name points
    /// at it. False when there is no such name.
    pub fn remove_name(self, const name: string) -> bool {
        var entry = f"{self.root}/by-name/{name}"
        if !LinkFS::exists(entry) && !LinkFS::is_dir(entry) {
            return false
        }

        var key = self.key_of(name)
        LinkFS::remove(entry)
        if !key.empty() && !self._referenced(key) {
            LinkFS::remove_tree(self.sysroot_dir(key))
        }

        return true
    }

    /// Drops sysroots no name points at, and stage dirs (finished, partial
    /// or failed) older than \p max_age_ticks before \p now. Returns what it
    /// removed, one path per entry.
    pub fn gc(self, now: u64, max_age_ticks: u64) -> cxx::std::vector<string> {
        var removed = cxx::std::vector<string>()
        for var name: string in LinkFS::list_dir(f"{self.root}/by-name") {
            if LinkText::starts_with(name, ".") {
                var p = f"{self.root}/by-name/{name}"
                LinkFS::remove(p)
                removed.push_back(p)
                continue
            }

            if self.key_of(name).empty() {
                var p = f"{self.root}/by-name/{name}"
                LinkFS::remove(p)
                removed.push_back(p)
            }
        }

        for var key: string in LinkFS::list_dir(f"{self.root}/sysroots") {
            if !self._referenced(key) {
                var p = self.sysroot_dir(key)
                LinkFS::remove_tree(p)
                removed.push_back(p)
            }
        }

        for var s: string in LinkFS::list_dir(f"{self.root}/stage") {
            var p = f"{self.root}/stage/{s}"
            var t = LinkFS::mtime(p)
            if t != 0 && now > t && now - t > max_age_ticks {
                LinkFS::remove_tree(p)
                removed.push_back(p)
            }
        }

        return removed
    }

    /// The cache filesystem's clock, read as a fresh file's mtime: gc
    /// compares it with entries' mtimes, which that same clock wrote.
    pub fn now(self) -> u64 {
        LinkFS::make_dirs(self.root)
        var p = f"{self.root}/.now-{llvm::sys::Process::getProcessId()}"
        LinkFS::write(p, "")
        var t = LinkFS::mtime(p)
        LinkFS::remove(p)
        return t
    }

    priv fn _referenced(self, const key: string) -> bool {
        for var name: string in LinkFS::list_dir(f"{self.root}/by-name") {
            if !LinkText::starts_with(name, ".") && self.key_of(name) == key {
                return true
            }
        }

        return false
    }

    priv static fn _slashes(s: string) -> string {
        var out = s
        eval if defined!(_WIN32) {
            for var i: usize = 0; i < out.size(); ++i {
                if out[i] == ('\\' as u8) {
                    out[i] = ('/' as u8)
                }
            }
        }

        return out
    }
}

/// A stage dir's life: `<dir>.tmp` while it is written, renamed to `<dir>`
/// with `.ok` inside on success, or to `<dir>.failed` (log/ kept) on failure.
pub class SysStage {
    pub var dir: string

    pub fn SysStage(self, const dir: string) {
        self.dir = dir
    }

    pub fn done(self) -> bool {
        return LinkFS::is_file(self.dir + "/.ok")
    }

    pub fn tmp(self) -> string {
        return self.dir + ".tmp"
    }

    pub fn log_dir(self) -> string {
        return self.tmp() + "/log"
    }

    /// A fresh `.tmp` with log/. Anything left by a crashed run goes first.
    pub fn begin(self) -> bool {
        LinkFS::remove_tree(self.tmp())
        return LinkFS::make_dirs(self.log_dir())
    }

    pub fn commit(self) -> bool {
        if !LinkFS::write(self.tmp() + "/.ok", "") {
            return false
        }

        LinkFS::remove_tree(self.dir + ".failed")
        LinkFS::remove_tree(self.dir)
        return LinkFS::rename(self.tmp(), self.dir)
    }

    /// Keeps the log as `<dir>.failed`; returns its log path.
    pub fn fail(self, const why: string) -> string {
        LinkFS::write(self.log_dir() + "/error.txt", why + "\n")
        LinkFS::remove_tree(self.dir + ".failed")
        LinkFS::rename(self.tmp(), self.dir + ".failed")
        return self.dir + ".failed/log"
    }

    /// A refusal is not a failure: nothing was attempted worth a log.
    pub fn abandon(self) {
        LinkFS::remove_tree(self.tmp())
    }
}
