/// --- The Kairo Project ------------------ Support/FileIO/AtomicFile.k --- ///
///
///   Atomic file publish for the caches, the stat they key entries on, and
///   the sweep of what an interrupted publish leaves behind.
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
ffi "c++" import "chrono"
ffi "c++" import "system_error"

import Support::Ascii::find
import Support::FileIO::Path::Path
import std::c_char

/// Temporaries minted by this process; with the pid it makes every
/// temporary name unique, across threads too.
var _TEMP_SEQ: u64 = 0

/// The private name a publish of \p path writes first:
/// `<path>.tmp-<pid>-<n>.tmp`, in \p path's directory so the rename stays
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

/// Moves \p from to \p to, a file or a directory. Atomic on one
/// filesystem. A file replaces an existing file at \p to; a directory
/// fails if \p to is a non-empty directory. False when the move fails;
/// \p from is then left where it was.
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

/// Writes \p bytes to \p path atomically (exact bytes, no newline
/// translation): through temp_path_for and rename_path. On failure the
/// temporary is removed and \p path is untouched.
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

/// Copies the file \p from to \p to atomically, as publish_bytes writes.
/// On failure the temporary is removed and \p to is untouched.
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

/// The last modification time and the size of \p path, symlinks followed.
/// \p mtime is nanoseconds since the Unix epoch, the clock now_ns reads, so
/// the two subtract to an age. False, with both left unchanged, when
/// \p path cannot be stat'd.
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

/// True when the directory entry \p name is something an interrupted
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

/// Removes every entry directly in \p dir that is_leftover_temp names and
/// that was last modified more than \p max_age_ns ago: a file, or a
/// directory with everything under it. An entry that cannot be stat'd is
/// kept. Returns how many were removed.
pub fn sweep_leftover_temps(const dir: string, max_age_ns: u64) -> usize {
    var now                           = now_ns()
    var removed: usize                = 0
    var ec:      cxx::std::error_code
    var it = llvm::sys::fs::directory_iterator(
        llvm::Twine(kairo::sref(dir)),
        &ec,
        true,
    )

    var end              = llvm::sys::fs::directory_iterator()
    var doomed: [string]
    while ec.value() == 0 && it != end {
        var raw = it->path()
        var p = string(
            unsafe ((raw.data() as unsafe *const u8) as *const u8),
            raw.size(),
        )

        it.increment(&ec)
        if !is_leftover_temp(Path::filename_of(p)) {
            continue
        }

        var mtime: u64 = 0
        var size:  u64 = 0
        if !file_stat(p, &mtime, &size) {
            continue
        }

        if now > mtime && now - mtime > max_age_ns {
            doomed.push_back(p)
        }
    }

    // Removed after the walk: the iterator must not see its directory change
    // under it.
    for var p: string in doomed {
        if llvm::sys::fs::is_directory(llvm::Twine(kairo::sref(p))) {
            Path::remove_tree(p)
        } else {
            Path::remove_file(p)
        }

        removed += 1
    }

    return removed
}
