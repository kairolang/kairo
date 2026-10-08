/// --- The Kairo Project --------------------------------- Lib/std/io.k --- ///
///
///   `println`. In builtin, not std, because it is the target FStringLowering
///   will write puts against directly once `println(f"...")` is lowered
///   without a FmtBuf, and a lowering target is a lang item.
///
///   Length-delimited and unbuffered: no printf, no NUL, one write(2) when
///   the line fits a stack page. A buffered writer is std's.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c" import "write.h"   // unistd.h, or io.h on Windows

import string::*

/// `s` and a newline to stdout.
pub fn println(const s: string) {
    if s.len < 4096 {
        var buf: [u8; 4096]                       // never initialized; only the bytes written are read
        for var i: usize = 0; i < s.len; ++i { buf[i] = s.data[i] }
        buf[s.len] = 10
        write_all_(1, &buf[0], s.len + 1)
        return
    }
    write_all_(1, s.data, s.len)
    var nl: [u8; 1]
    nl[0] = 10
    write_all_(1, &nl[0], 1)
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