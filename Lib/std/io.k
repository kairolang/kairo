/// --- The Kairo Project --------------------------------- Lib/std/io.k --- ///
///
///   Unbuffered, length-delimited writes to stdout and stderr: `print`,
///   `println`, `eprint`, `eprintln`, and `flush` for C stdio output.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c" import "write.h"   // unistd.h, or io.h on Windows; stdio.h for flush

import string::*

/// Writes `s` followed by a newline to standard output.
///
/// Unbuffered: the bytes are out when the call returns. A line shorter than 4096 bytes goes
/// out in a single `write(2)`, so concurrent lines from different threads are not split.
/// Longer lines take two writes (the text, then the newline). Write errors are ignored.
///
/// \param s   the text to write
/// \example
/// ```kairo
/// import std::io
///
/// fn main() -> i32 {
///     io::println("hello")
///     return 0
/// }
/// ```
pub fn println(const s: string) { write_line_(1, s) }

/// Writes `s` to standard output without a trailing newline.
///
/// Unbuffered, like `println`. Write errors are ignored.
///
/// \param s   the text to write
pub fn print(const s: string) { write_all_(1, s.as_ptr(), s.length()) }

/// Writes `s` followed by a newline to standard error.
///
/// Same single-write behaviour as `println`. Because neither stream is buffered, output to
/// stdout and stderr interleaves in call order when both go to the same place (`2>&1`).
///
/// \param s   the text to write
pub fn eprintln(const s: string) { write_line_(2, s) }

/// Writes `s` to standard error without a trailing newline.
///
/// \param s   the text to write
pub fn eprint(const s: string) { write_all_(2, s.as_ptr(), s.length()) }

/// Flushes the C runtime's stdio buffers on every stream.
///
/// Nothing in `std::io` buffers, so this exists only for ordering against C and C++ code that
/// writes through stdio (`printf`, `fwrite(stdout)`, a C++ library). stdout is block-buffered
/// when it is a pipe or a file, so bytes such code wrote before a print here can otherwise
/// appear after it. Call `flush` at that boundary.
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