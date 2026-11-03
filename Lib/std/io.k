/// --- The Kairo Project --------------------------------- Lib/std/io.k --- ///
///
///   `print`, `println`, `eprint`, `eprintln`, `flush`.
///
///   `println`: in builtin, not std, because it is the target FStringLowering
///   will write puts against directly once `println(f"...")` is lowered
///   without a FmtBuf, and a lowering target is a lang item.
///
///   Length-delimited and unbuffered: no printf, no NUL, one write(2) when
///   a line fits a stack page. A buffered writer is std's, later. Because
///   nothing here buffers, stdout and stderr interleave in call order under
///   2>&1; C stdio output is the one thing that can come out of order, and
///   `flush` is for that boundary.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c" import "write.h"   // unistd.h, or io.h on Windows; stdio.h for flush

import string::*

/// `s` and a newline to stdout.
pub fn println(const s: string) { write_line_(1, s) }

/// `s` to stdout, no newline.
pub fn print(const s: string) { write_all_(1, s.as_ptr(), s.length()) }

/// `s` and a newline to stderr.
pub fn eprintln(const s: string) { write_line_(2, s) }

/// `s` to stderr, no newline.
pub fn eprint(const s: string) { write_all_(2, s.as_ptr(), s.length()) }

/// Pushes out whatever the C runtime's stdio is still buffering, on every
/// stream. Nothing in this file buffers -- each call above is out by the time
/// it returns -- so this is for ordering against C and C++ code that writes
/// through stdio (printf, fwrite(stdout), a C++ library): stdout is
/// block-buffered when it is a pipe or a file, so bytes such code wrote
/// BEFORE a print here can land AFTER it unless flushed first.
pub fn flush() {
    unsafe { kstd_flush_stdio() }
}

/// One write(2) for the line and its newline when it fits a stack page, so a
/// line from one thread is never split by another's (and a reader of a pipe
/// sees whole lines); a longer one is two writes.
priv fn write_line_(fd: i32, const s: string) {
    const n = s.length()
    if n < 4096 {
        var buf: [u8; 4096]                       // never initialized; only the bytes written are read
        for var i: usize = 0; i < n; ++i { buf[i] = s.as_ptr()[i] }
        buf[n] = 10
        write_all_(fd, &buf[0], n + 1)
        return
    }
    write_all_(fd, s.as_ptr(), n)
    var nl: [u8; 1]
    nl[0] = 10
    write_all_(fd, &nl[0], 1)
}

/// write(2) is short on pipes and sockets; loop until every byte is out. Each
/// chunk is capped at 0x7FFFF000: Linux clamps there anyway (MAX_RW_COUNT),
/// and msvcrt's write takes unsigned int and returns int. A negative return is
/// an error; errno is a macro and cannot be imported, so EINTR is
/// indistinguishable and is treated as one. Zero is treated as an error too,
/// or the loop never terminates. This function will be able to crash! later.
priv fn write_all_(fd: i32, p: *const u8, n: usize) {
    var cap: usize = 0x7FFFF000
    var off: usize = 0
    while off < n {
        var chunk: usize = n - off
        if chunk > cap { chunk = cap }
        unsafe {
            var w = write(fd, unsafe &p[off], chunk as u32)
            if w <= 0 { return }
            off += w as usize
        }
    }
}