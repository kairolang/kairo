/// --- The Kairo Project ------------------------------- Sysroot/SysRun.k --- ///
///
///   SysRun: what the build stages do to the outside world. Spawning a tool
///   with its output in a log file, a window of parallel compiles, and the
///   tree copies the stages lay roots out with.
///
///   Tree copies keep symlinks as symlinks: the BSD bases link usr/lib/*.so
///   to ../../lib, glibc's headers carry a few, and a link that became a
///   file would be a second copy that drifts from the first. Windows, where
///   a symlink needs a privilege, copies the target instead.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "filesystem"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "llvm/Support/Threading.h"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::Text::LinkText

pub class SysRun {
    /// Runs \p argv (argv[0] a path) with stdout and stderr both in \p log
    /// (appended to nothing: the file is replaced). The exit status, or -1
    /// when the program could not be started; \p log then says why.
    pub static fn run(@inout argv: cxx::std::vector<string>, const log: string) -> i32 {
        if argv.empty() {
            return -1
        }

        // Views of argv's own bytes; argv is not touched while refs lives.
        var refs: cxx::std::vector<llvm::StringRef>
        refs.reserve(argv.size())
        for var i: usize = 0; i < argv.size(); ++i {
            refs.push_back(kairo::sref(argv[i]))
        }

        var nlog = kairo::std::to_std_string(log)
        var redir: cxx::std::vector<cxx::std::optional<llvm::StringRef>>
        redir.push_back(cxx::std::optional<llvm::StringRef>(cxx::std::nullopt))
        redir.push_back(cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)))
        redir.push_back(cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)))

        var emsg:  cxx::std::string
        var failed                  = false
        var rc = llvm::sys::ExecuteAndWait(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
            cxx::std::optional<llvm::ArrayRef<llvm::StringRef>>(cxx::std::nullopt),
            llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>(redir),
            0,
            0,
            unsafe &emsg,
            unsafe &failed,
        )

        if failed {
            var why = string(unsafe ((emsg.data() as unsafe *const u8) as *const u8), emsg.size())
            LinkFS::write(log, f"cannot run {argv[0]}: {why}\n")
            return -1
        }

        return rc
    }

    /// How many compiles a stage keeps in flight: KSYS_JOBS, else the
    /// hardware's thread count.
    pub static fn jobs() -> usize {
        var e        = LinkFS::env("KSYS_JOBS")
        var n: usize = 0
        for var i: usize = 0; i < e.size(); ++i {
            if e[i] < ('0' as u8) || e[i] > ('9' as u8) {
                n = 0
                break
            }

            n = n * 10 + ((e[i] - ('0' as u8)) as usize)
        }

        if n == 0 {
            n = (llvm::hardware_concurrency().compute_thread_count() as usize)
        }

        return if (n == 0) => (1 as usize) else => n
    }

    /// The target of the symlink \p p; "" when \p p is not one (or on
    /// Windows, where trees are copied with links followed).
    pub static fn read_link(const p: string) -> string {
        eval if defined!(_WIN32) {
            return ""
        }

        if !llvm::sys::fs::is_symlink_file(llvm::Twine(kairo::sref(p))) {
            return ""
        }

        var ec: cxx::std::error_code
        var sp                       = kairo::std::to_std_string(p)
        var t = cxx::std::filesystem::read_symlink(cxx::std::filesystem::path(sp), &ec)
        if ec.value() != 0 {
            return ""
        }

        var ts = t.generic_string()
        return string(unsafe ((ts.data() as unsafe *const u8) as *const u8), ts.size())
    }

    /// A symlink at \p at reading \p target (relative targets stay
    /// relative). False where links cannot be made.
    pub static fn symlink(const target: string, const at: string) -> bool {
        LinkFS::remove(at)
        var t = target
        var ec = llvm::sys::fs::create_link(
            llvm::Twine(kairo::sref(t)),
            llvm::Twine(kairo::sref(at)),
        )

        return ec.value() == 0
    }

    /// Copies \p from into \p to (merged into what is there), symlinks kept
    /// as symlinks. \p skip names top-level entries to leave out.
    pub static fn copy_tree(const from:  string,
                            const to:    string,
                            @inout skip: cxx::std::vector<string>) -> bool {
        return SysRun::_tree(from, to, &skip, false, 0)
    }

    /// As copy_tree, but regular files are hard links where the filesystem
    /// allows one (a copy where it does not). For laying a finished stage
    /// into a root: both sides are cache dirs nothing writes to again.
    pub static fn link_tree(const from:  string,
                            const to:    string,
                            @inout skip: cxx::std::vector<string>) -> bool {
        return SysRun::_tree(from, to, &skip, true, 0)
    }

    /// One file, \p from to \p to (parents made), as a hard link when
    /// \p hard and possible, else a copy. A symlink stays one.
    pub static fn put_file(const from: string, const to: string, hard: bool) -> bool {
        LinkFS::make_dirs(LinkFS::parent(to))
        var tgt = SysRun::read_link(from)
        if !tgt.empty() {
            return SysRun::symlink(tgt, to)
        }

        LinkFS::remove(to)
        if hard {
            var ec = llvm::sys::fs::create_hard_link(
                llvm::Twine(kairo::sref(from)),
                llvm::Twine(kairo::sref(to)),
            )

            if ec.value() == 0 {
                return true
            }
        }

        var cec = llvm::sys::fs::copy_file(
            llvm::Twine(kairo::sref(from)),
            llvm::Twine(kairo::sref(to)),
        )

        return cec.value() == 0
    }

    priv static fn _tree(const from:  string,
                         const to:    string,
                         @inout skip: cxx::std::vector<string>,
                         hard:        bool,
                         depth:       u32) -> bool {
        if depth > 64 || !LinkFS::make_dirs(to) {
            return false
        }

        var none = cxx::std::vector<string>()
        for var name: string in LinkFS::list_dir(from) {
            var found = false
            for var s: string in skip {
                if s == name {
                    found = true
                }
            }

            if found {
                continue
            }

            var s    = from + "/" + name
            var d    = to + "/" + name
            var link = SysRun::read_link(s)
            if !link.empty() {
                if !SysRun::symlink(link, d) {
                    return false
                }

                continue
            }

            if LinkFS::is_dir(s) {
                if !SysRun::_tree(s, d, &none, hard, depth + 1) {
                    return false
                }

                continue
            }

            if !LinkFS::is_file(s) {
                continue
            }

            if !SysRun::put_file(s, d, hard) {
                return false
            }
        }

        return true
    }
}

/// A window of up to SysRun::jobs() child processes. add() starts one,
/// first waiting for the oldest when the window is full; wait_all() drains
/// it. The first failure is kept and nothing new starts after it, so a
/// broken compile ends the stage instead of a thousand more.
pub class SysJobs {
    pub var  failed_log: string ///< log of the first job that failed, "" none
    pub var  failed_rc:  i32                                      = 0
    priv var _max:       usize                                    = 1
    priv var _pis:       cxx::std::vector<llvm::sys::ProcessInfo>
    priv var _logs:      cxx::std::vector<string>
    priv var _head:      usize                                    = 0

    pub fn SysJobs(self) {
        self._max = SysRun::jobs()
    }

    pub fn ok(self) -> bool {
        return self.failed_log.empty()
    }

    /// At most \p n in flight instead of SysRun::jobs(); 0 keeps that.
    pub fn limit(self, n: usize) {
        if n > 0 {
            self._max = n
        }
    }

    /// Starts \p argv with its output in \p log. False once any job failed.
    pub fn add(self, @inout argv: cxx::std::vector<string>, const log: string) -> bool {
        if !self.ok() {
            return false
        }

        while self._pis.size() - self._head >= self._max {
            self._reap_one()
        }

        if !self.ok() {
            return false
        }

        var refs: cxx::std::vector<llvm::StringRef>
        refs.reserve(argv.size())
        for var i: usize = 0; i < argv.size(); ++i {
            refs.push_back(kairo::sref(argv[i]))
        }

        var nlog = kairo::std::to_std_string(log)
        var redir: cxx::std::vector<cxx::std::optional<llvm::StringRef>>
        redir.push_back(cxx::std::optional<llvm::StringRef>(cxx::std::nullopt))
        redir.push_back(cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)))
        redir.push_back(cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)))

        var emsg:  cxx::std::string
        var failed                  = false
        var pi = llvm::sys::ExecuteNoWait(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
            cxx::std::optional<llvm::ArrayRef<llvm::StringRef>>(cxx::std::nullopt),
            llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>(redir),
            0,
            unsafe &emsg,
            unsafe &failed,
        )

        if failed {
            var why = string(unsafe ((emsg.data() as unsafe *const u8) as *const u8), emsg.size())
            LinkFS::write(log, f"cannot run {argv[0]}: {why}\n")
            self.failed_log = log
            self.failed_rc  = -1
            return false
        }

        self._pis.push_back(pi)
        self._logs.push_back(log)
        return true
    }

    /// Waits for every job started. True when all of them exited 0.
    pub fn wait_all(self) -> bool {
        while self._head < self._pis.size() {
            self._reap_one()
        }

        return self.ok()
    }

    priv fn _reap_one(self) {
        var emsg: cxx::std::string
        var done = llvm::sys::Wait(
            self._pis[self._head],
            cxx::std::optional<u32>(cxx::std::nullopt),
            unsafe &emsg,
        )

        var log = self._logs[self._head]
        self._head += 1
        if done.ReturnCode != 0 && self.failed_log.empty() {
            self.failed_log = log
            self.failed_rc  = done.ReturnCode
        }
    }
}
