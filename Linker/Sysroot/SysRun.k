/// --- The Kairo Project ------------------------------- Sysroot/SysRun.k --- ///
///
///   SysRun: what the build stages do to the outside world. Spawning a tool
///   with its output in a log file, a window of parallel compiles, and the
///   tree copies the stages lay roots out with.
///
///   Tree copies keep symlinks as symlinks: the BSD bases link usr/lib/*.so
///   to ../../lib, and a link that became a file would be a second copy that
///   drifts from the first. Windows, where a symlink needs a privilege,
///   copies the target instead. A schema 2 share input holds no links at
///   all (a zip cannot carry them to Windows): materialise() makes
///   them in the root from the input's links.tsv, and restores the
///   case-colliding names casefold.tsv records.
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
import Sysroot::SysUtil::SysUtil

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
        redir.push_back(
            cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)),
        )

        redir.push_back(
            cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)),
        )

        var emsg:  cxx::std::string
        var failed                  = false
        var rc = llvm::sys::ExecuteAndWait(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
            cxx::std::optional<llvm::ArrayRef<llvm::StringRef>>(
                cxx::std::nullopt,
            ),
            llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>(redir),
            0,
            0,
            unsafe &emsg,
            unsafe &failed,
        )

        if failed {
            var why = string(
                unsafe ((emsg.data() as unsafe *const u8) as *const u8),
                emsg.size(),
            )

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
        var t = cxx::std::filesystem::read_symlink(
            cxx::std::filesystem::path(sp),
            &ec,
        )

        if ec.value() != 0 {
            return ""
        }

        var ts = t.generic_string()
        return string(
            unsafe ((ts.data() as unsafe *const u8) as *const u8),
            ts.size(),
        )
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

    /// Copies \p from, a dir inside the share input \p root ("" when it is
    /// in none), to \p to, then recreates what a schema 2 input records
    /// instead of holding (FORMAT.md "schema 2"): each <root>/links.tsv row
    /// under \p from as the same symlink, or as a copy of what the row
    /// resolves to where no link can be made; each <root>/casefold.tsv row
    /// renamed back to its real name, or dropped when \p to cannot tell the
    /// two names apart. Neither file sits under a copied subdir, so neither
    /// reaches a root. False with \p err set on any failure.
    pub static fn materialise(const root: string,
                              const from: string,
                              const to:   string,
                              @inout err: string) -> bool {
        var none = cxx::std::vector<string>()
        if !SysRun::copy_tree(from, to, &none) {
            err = f"cannot copy {from} to {to}"
            return false
        }

        if root.empty() {
            return true
        }

        var sub = if (from == root) => ("")
                  else => LinkText::slice(from, root.size() + 1, from.size())
        var rels = cxx::std::vector<string>()
        var tgts = cxx::std::vector<string>()
        var text = ""
        if LinkFS::read(root + "/links.tsv", &text) {
            for var line: string in LinkText::split_lines(text) {
                if line.empty() {
                    continue
                }

                var cols = SysUtil::split(line, ('\t' as u8))
                if cols.size() != 3 {
                    err = f"{root}/links.tsv: malformed row \x27{line}\x27"
                    return false
                }

                rels.push_back(cols[0])
                tgts.push_back(cols[1])
            }
        }

        // Rows are independent: a chain may dangle until its last link is
        // made. Copies wait until every link that could be made is.
        var copies = cxx::std::vector<usize>()
        for var i: usize = 0; i < rels.size(); ++i {
            var at = SysRun::_mapped(sub, rels[i], to)
            if at.empty() {
                continue
            }

            LinkFS::make_dirs(LinkFS::parent(at))
            // llvm's create_link is a hard link on Windows, resolved against
            // the working directory: never a substitute for the row.
            var linked = false
            eval if defined!(_WIN32) {
                linked = false
            } else {
                linked = SysRun::symlink(tgts[i], at)
            }

            if !linked {
                copies.push_back(i)
            }
        }

        for var i: usize in copies {
            var at  = SysRun::_mapped(sub, rels[i], to)
            var res = SysRun::_resolve_recorded(root, rels[i], &rels, &tgts)
            if res.empty() {
                err = f"{root}/links.tsv: {rels[i]} -> {tgts[i]} does not resolve inside the input"
                return false
            }

            var src = root + "/" + res
            LinkFS::remove(at)
            var ok = if (LinkFS::is_dir(src)) => (SysRun::copy_tree(
                         src,
                         at,
                         &none,
                     ))
                     else => SysRun::put_file(src, at, false)
            if !ok {
                err = f"cannot copy {src} to {at} (in place of the link {rels[i]})"
                return false
            }
        }

        text = ""
        if !LinkFS::read(root + "/casefold.tsv", &text) {
            return true
        }

        var stored = cxx::std::vector<string>()
        var real   = cxx::std::vector<string>()
        for var line: string in LinkText::split_lines(text) {
            if line.empty() {
                continue
            }

            var cols = SysUtil::split(line, ('\t' as u8))
            if cols.size() != 2 {
                err = f"{root}/casefold.tsv: malformed row \x27{line}\x27"
                return false
            }

            var s = SysRun::_mapped(sub, cols[0], to)
            if !s.empty() {
                stored.push_back(s)
                real.push_back(SysRun::_mapped(sub, cols[1], to))
            }
        }

        if stored.empty() {
            return true
        }

        // The destination decides, not the host: a case-sensitive volume
        // on Windows or macOS keeps both names.
        var folds = SysRun::case_insensitive(to)
        for var i: usize = 0; i < stored.size(); ++i {
            if folds {
                LinkFS::remove(stored[i])
            } else if !LinkFS::rename(stored[i], real[i]) {
                err = f"cannot rename {stored[i]} to {real[i]}"
                return false
            }
        }

        return true
    }

    /// Whether the filesystem holding \p dir folds case: one probe file,
    /// looked up under its upper-case name.
    pub static fn case_insensitive(const dir: string) -> bool {
        var probe = dir + "/.kairo-case-probe"
        if !LinkFS::write(probe, "") {
            return false
        }

        var folds = LinkFS::exists(dir + "/.KAIRO-CASE-PROBE")
        LinkFS::remove(probe)
        return folds
    }

    /// \p rel (input-relative) under the copied subdir \p sub, as a path
    /// under \p to; "" when \p rel is not under \p sub.
    priv static fn _mapped(const sub: string, const rel: string, const to: string) -> string {
        if sub.empty() {
            return to + "/" + rel
        }

        if !LinkText::starts_with(rel, sub + "/") {
            return ""
        }

        return to + "/" + LinkText::slice(rel, sub.size() + 1, rel.size())
    }

    /// The link-free path inside \p root that the recorded link \p rel
    /// names, through chains and dir links as the OS would resolve them;
    /// "" when it escapes \p root, loops or dangles. The twin of
    /// Scripts/ship_sysroot_inputs.py resolve_recorded().
    priv static fn _resolve_recorded(const root:  string,
                                     const rel:   string,
                                     @inout rels: cxx::std::vector<string>,
                                     @inout tgts: cxx::std::vector<string>) -> string {
        var parts       = SysUtil::split(rel, ('/' as u8))
        var done        = cxx::std::vector<string>()
        var seen: usize = 0
        var head: usize = 0
        while head < parts.size() {
            var cur = SysUtil::joined(&done, "/")
            cur = if (cur.empty()) => (parts[head]) else => cur + "/" + parts[head]
            var hit = rels.size()
            for var i: usize = 0; i < rels.size(); ++i {
                if rels[i] == cur {
                    hit = i
                }
            }

            if hit < rels.size() {
                seen += 1
                if seen > 64 {
                    return ""
                }

                var next = SysUtil::split(tgts[hit], ('/' as u8))
                for var i: usize = head + 1; i < parts.size(); ++i {
                    next.push_back(parts[i])
                }

                parts = next
                head  = 0
                continue
            }

            var h = parts[head]
            head += 1
            if h.empty() || h == "." {
                continue
            }

            if h == ".." {
                if done.empty() {
                    return ""
                }

                done.pop_back()
                continue
            }

            done.push_back(h)
        }

        var res = SysUtil::joined(&done, "/")
        if res.empty() || !LinkFS::exists(root + "/" + res) {
            return ""
        }

        return res
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
        redir.push_back(
            cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)),
        )

        redir.push_back(
            cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)),
        )

        var emsg:  cxx::std::string
        var failed                  = false
        var pi = llvm::sys::ExecuteNoWait(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
            cxx::std::optional<llvm::ArrayRef<llvm::StringRef>>(
                cxx::std::nullopt,
            ),
            llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>(redir),
            0,
            unsafe &emsg,
            unsafe &failed,
        )

        if failed {
            var why = string(
                unsafe ((emsg.data() as unsafe *const u8) as *const u8),
                emsg.size(),
            )

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
