/// --- The Kairo Project ------------------ Support/FileIO/AtomicFile.k --- ///
///
///   Atomic file publish for the caches, the stat they key entries on, the
///   sweep of what an interrupted publish leaves behind, and the lock file
///   a publish that must check before it renames holds.
///
///   A cache shared by parallel builds must never let a reader see half an
///   entry. A publish writes a private temporary beside the destination and
///   renames it over the destination: on one filesystem the rename is
///   atomic, so a reader opens the old entry or the new one, never a torn
///   one. Two writers of the same entry write the same bytes, and the last
///   rename wins.
///
///   Portable through llvm::sys::fs. On Windows llvm's rename replaces an
///   existing file (SetFileInformationByHandle with ReplaceIfExists, then
///   MoveFileExW with MOVEFILE_REPLACE_EXISTING), but it opens the source as
///   a file, so a directory never moves; rename_path then moves it through
///   Native/Win32's move_path. A rename that Windows refuses (the destination is open or
///   mapped) is a failed publish, not an error: the caller treats the entry
///   as not stored.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Win32.hh" // move_path (Windows directory renames)
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "chrono"
ffi "c++" import "system_error"
ffi "c++" import "thread"

import Support::Ascii::find
import Support::FileIO::Path::Path
import std::c_char
import std::io

/// Temporaries minted by this process; with the pid it makes every
/// temporary name unique, across threads too.
var _TEMP_SEQ: u64 = 0

/// The private name a publish of `path` writes first:
/// `<path>.tmp-<pid>-<n>.tmp`, in `path`'s directory so the rename stays
/// on one filesystem. Both ends mark it (see is_leftover_temp), and it
/// never ends in an entry's own suffix (`.o`), so a sweep of entries by
/// suffix skips it.
pub fn temp_path_for(const path: string) -> string {
    var n = __builtin_atomic_fetch_add(
        &_TEMP_SEQ,
        1 as u64,
        MemoryOrder::Relaxed,
    )

    return f"{path}.tmp-{llvm::sys::Process::getProcessId()}-{n}.tmp"
}

/// Moves `from` to `to`, a file or a directory. Atomic on one
/// filesystem. A file replaces an existing file at `to`; a directory
/// fails if `to` is a non-empty directory. False when the move fails;
/// `from` is then left where it was.
pub fn rename_path(const from: string, const to: string) -> bool {
    var ec = llvm::sys::fs::rename(
        llvm::Twine(kairo::sref(from)),
        llvm::Twine(kairo::sref(to)),
    )

    if ec.value() == 0 {
        return true
    }

    // llvm's Windows rename opens the source as a file, so a directory
    // never moves there; MoveFileExW moves either.
    eval if defined!(_WIN32) {
        return kairo::win32::move_path(
            unsafe ((from.raw() as unsafe *const u8) as unsafe *const c_char),
            from.size(),
            unsafe ((to.raw() as unsafe *const u8) as unsafe *const c_char),
            to.size(),
        )
    }

    return false
}

/// Writes `bytes` to `path` atomically (exact bytes, no newline
/// translation): through temp_path_for and rename_path. On failure the
/// temporary is removed and `path` is untouched.
pub fn publish_bytes(const path: string, const bytes: string) -> bool {
    var tmp = temp_path_for(path)
    if !Path::write_file(tmp, bytes) {
        Path::remove_file(tmp)
        return false
    }

    if !rename_path(tmp, path) {
        Path::remove_file(tmp)
        return false
    }

    return true
}

/// Copies the file `from` to `to` atomically, as publish_bytes writes.
/// On failure the temporary is removed and `to` is untouched.
pub fn publish_copy(const from: string, const to: string) -> bool {
    var tmp = temp_path_for(to)
    var ec = llvm::sys::fs::copy_file(
        llvm::Twine(kairo::sref(from)),
        llvm::Twine(kairo::sref(tmp)),
    )

    if ec.value() != 0 {
        Path::remove_file(tmp)
        return false
    }

    if !rename_path(tmp, to) {
        Path::remove_file(tmp)
        return false
    }

    return true
}

/// The last modification time and the size of `path`, symlinks followed.
/// `mtime` is nanoseconds since the Unix epoch, the clock now_ns reads, so
/// the two subtract to an age. False, with both left unchanged, when
/// `path` cannot be stat'd.
pub fn file_stat(const path: string, @inout mtime: u64, @inout size: u64) -> bool {
    var st: llvm::sys::fs::file_status
    var ec = llvm::sys::fs::status(llvm::Twine(kairo::sref(path)), &st, true)
    if ec.value() != 0 {
        return false
    }

    mtime = st.getLastModificationTime().time_since_epoch().count() as u64
    size  = st.getSize() as u64
    return true
}

/// Now, in nanoseconds since the Unix epoch: the clock file_stat's mtime
/// is on.
pub fn now_ns() -> u64 {
    return (cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
        cxx::std::chrono::system_clock::now().time_since_epoch(),
    ).count() as u64)
}

/// True when the directory entry `name` is something an interrupted
/// publish left: a temporary (`.tmp-` anywhere, or a `.tmp` suffix), a
/// stale tree moved aside before a replace (`.stale-`), or a copy made to
/// publish a tree that could not be renamed (`.copy-`). Never a cache
/// entry, so a sweep may remove it once it is old enough that no live
/// publish still owns it.
pub fn is_leftover_temp(const name: string) -> bool {
    return find(name, ".tmp-", 0) != usize::MAX
        || name.ends_with(".tmp")
        || find(name, ".stale-", 0) != usize::MAX
        || find(name, ".copy-", 0) != usize::MAX
}

/// True when `name` is a temporary of a publish of the file `base`:
/// `<base>.tmp-<pid>-<n>.tmp` (temp_path_for).
pub fn is_temp_of(const name: string, const base: string) -> bool {
    return name.starts_with(base.copy() + ".tmp-") && name.ends_with(".tmp")
}

/// Adds to `doomed` every entry of `dir` that `base` selects (is_temp_of
/// `base`, or is_leftover_temp when `base` is empty) and that was last
/// modified more than `max_age_ns` before `now`; with `deep`, the
/// subdirectories are walked too. An entry that cannot be stat'd is kept.
fn collect_stale_(const dir:  string,
                  const base: string,
                  deep:       bool,
                  now:        u64,
                  max_age_ns: u64,
                  doomed:     *[string]) {
    var ec: cxx::std::error_code
    var it = llvm::sys::fs::directory_iterator(
        llvm::Twine(kairo::sref(dir)),
        &ec,
        true,
    )

    var end            = llvm::sys::fs::directory_iterator()
    var subs: [string]
    while ec.value() == 0 && it != end {
        var raw = it->path()
        var p = string(
            unsafe ((raw.data() as unsafe *const u8) as *const u8),
            raw.size(),
        )

        it.increment(&ec)
        var name = Path::filename_of(p)
        var hit = if base.is_empty() => is_leftover_temp(name) else => is_temp_of(name, base)
        if !hit {
            if deep && llvm::sys::fs::is_directory(llvm::Twine(kairo::sref(p))) {
                subs.push(p.copy())
            }

            continue
        }

        var mtime: u64 = 0
        var size:  u64 = 0
        if !file_stat(p, &mtime, &size) {
            continue
        }

        if now > mtime && now - mtime > max_age_ns {
            doomed->push(p.copy())
        }
    }

    for var q: usize = 0; q < subs.size(); ++q {
        collect_stale_(subs[q], base, deep, now, max_age_ns, doomed)
    }
}

/// Removes what collect_stale_ names; returns how many.
fn remove_stale_(const dir: string, const base: string, deep: bool, max_age_ns: u64) -> usize {
    var doomed: [string]
    // Removed after the walk: the iterator must not see its directory change
    // under it.
    collect_stale_(dir, base, deep, now_ns(), max_age_ns, &doomed)
    var removed: usize = 0
    for p in doomed {
        if llvm::sys::fs::is_directory(llvm::Twine(kairo::sref(p))) {
            Path::remove_tree(p)
        } else {
            Path::remove_file(p)
        }

        removed += 1
    }

    return removed
}

/// Removes every entry directly in `dir` that is_leftover_temp names and
/// that was last modified more than `max_age_ns` ago: a file, or a
/// directory with everything under it. An entry that cannot be stat'd is
/// kept. Returns how many were removed.
pub fn sweep_leftover_temps(const dir: string, max_age_ns: u64) -> usize {
    return remove_stale_(dir, "", false, max_age_ns)
}

/// As sweep_leftover_temps, over `dir` and every directory under it: for
/// a tree only the publisher writes into.
pub fn sweep_leftover_temps_tree(const dir: string, max_age_ns: u64) -> usize {
    return remove_stale_(dir, "", true, max_age_ns)
}

/// Removes the temporaries of publishes of the file `base` (is_temp_of)
/// directly in `dir` that are older than `max_age_ns`, and nothing else: for
/// a directory other files live in. Returns how many were removed.
pub fn sweep_temps_of(const dir: string, const base: string, max_age_ns: u64) -> usize {
    return remove_stale_(dir, base, false, max_age_ns)
}

/// Creates the file `path` only if nothing is there, in one step: llvm's
/// CD_CreateNew is O_CREAT | O_EXCL, and CREATE_NEW on Windows, so of two
/// processes creating one path exactly one succeeds.
priv fn _create_new(const path: string) -> bool {
    var ec: cxx::std::error_code
    var os = llvm::raw_fd_ostream(
        kairo::sref(path),
        &ec,
        llvm::sys::fs::CD_CreateNew,
    )

    return ec.value() == 0
}

/// Takes the lock file `path` for this process, waiting up to `wait_ns`
/// for another holder to drop it (lock_file_drop).
///
/// The lock is the file's existence, made by _create_new. A lock older
/// than `stale_ns` is taken over: its holder crashed or was killed, since a
/// live one holds it only for a short check-and-publish. The age is read
/// again right before the stale file is removed, so a lock another process
/// took over in between, which has a new mtime, is left to it. An age is
/// used rather than the holder's process id: whether a pid is alive cannot
/// be asked the same way on every host, and a pid can be reused.
///
/// False when the lock is still held after `wait_ns`, or cannot be
/// created at all (the directory is missing or read-only); the caller
/// then goes on without it.
pub fn lock_file_take(const path: string, stale_ns: u64, wait_ns: u64) -> bool {
    var start        = now_ns()
    var pause: i64   = 100      // microseconds, doubled up to 10 ms
    var gone:  usize = 0
    while true {
        if _create_new(path) {
            return true
        }

        var mtime: u64 = 0
        var size:  u64 = 0
        if !file_stat(path, &mtime, &size) {
            // Dropped between the create and the stat: try again at once. A
            // create that keeps failing with no file there cannot work.
            gone += 1
            if gone > 16 {
                return false
            }

            continue
        }

        var now = now_ns()
        if now >= mtime && now - mtime >= stale_ns {
            var again: u64 = 0
            if file_stat(path, &again, &size) && again == mtime {
                Path::remove_file(path)
            }

            continue
        }

        if now >= start && now - start >= wait_ns {
            return false
        }

        cxx::std::this_thread::sleep_for(cxx::std::chrono::microseconds(pause))
        if pause < 10000 {
            pause *= 2
        }
    }

    return false
}

/// Drops the lock lock_file_take took.
pub fn lock_file_drop(const path: string) {
    Path::remove_file(path)
}

pub fn Test() -> i32 {
    var errors = 0
    var check = fn (what: string, ok: bool) -> i32 {
        if ok {
            return 0
        }

        io::println(f"FAIL: {what}")
        return 1
    }

    var dir = Path::make_temp_dir("kairo-lock-test")
    if dir.is_empty() {
        io::println("FAIL: no temp dir")
        return 1
    }

    var lock = dir.copy() + "/entry.lock"
    var day  = (86400 as u64) * (1000000000 as u64)
    errors += check("take a free lock", lock_file_take(lock, day, 0))
    errors += check("the lock is a file", Path::exists_at(lock))
    errors += check(
        "a fresh lock is not taken twice",
        !lock_file_take(lock, day, 0),
    )

    errors += check(
        "a held lock is waited for, then refused",
        !lock_file_take(lock, day, 20000000),
    )

    errors += check("a stale lock is taken over", lock_file_take(lock, 0, 0))
    errors += check(
        "taken over, it is still held",
        !lock_file_take(lock, day, 0),
    )

    lock_file_drop(lock)
    errors += check("dropped, it is gone", !Path::exists_at(lock))
    errors += check("dropped, it is free", lock_file_take(lock, day, 0))
    lock_file_drop(lock)
    errors += check(
        "no directory, no lock",
        !lock_file_take(dir.copy() + "/none/entry.lock", day, day),
    )

    Path::remove_tree(dir)
    return errors
}
