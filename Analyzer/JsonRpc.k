/// --- The Kairo Project --------------------------- Analyzer/JsonRpc.k --- ///
///
///   JSON-RPC 2.0 message framing and dispatch over stdio.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c" import "kals_io.h"

import std::io

/// \class Transport
/// \brief Content-Length framed messages over stdin/stdout.
///
/// \details Reads are non-blocking past a timeout: `wait(ms)` returns as soon
///          as one whole message is buffered, or after \p ms with none. The
///          server's loop runs on that timeout, which is what lets it notice a
///          finished worker while the editor is silent.
pub class Transport {
    pub var closed: bool = false ///< stdin reached EOF or failed: the editor is gone

    priv var buf_:  string = ""
    priv var head_: usize  = 0  ///< bytes of buf_ already consumed

    fn Transport(self) {
        unsafe { kals_stdio_binary() }
    }

    /// True when a complete message is buffered (take() will return it).
    fn wait(self, ms: i32) -> bool {
        if self.frame_len_() != usize::MAX {
            return true
        }

        if self.closed {
            return false
        }

        var ready: i32 = unsafe kals_stdin_wait(ms)
        if ready == 0 {
            return false
        }

        var chunk: [u8; 65536]
        var got: i64 = unsafe kals_stdin_read(unsafe &chunk[0], 65536)
        if got <= 0 {
            self.closed = true
            return false
        }

        // Compact before appending: without it the buffer keeps every message
        // of the session, and a long one is megabytes of consumed bytes.
        if self.head_ > 0 {
            self.buf_  = self.buf_.subslice(self.head_, self.buf_.size() - self.head_)
            self.head_ = 0
        }

        self.buf_ += string(unsafe (&chunk[0] as *const u8), got as usize)
        return self.frame_len_() != usize::MAX
    }

    /// The next message body. Call only after wait() returned true.
    fn take(self) -> string {
        var n = self.frame_len_()
        if n == usize::MAX {
            return ""
        }

        var start = self.body_start_()
        var body  = self.buf_.subslice(start, n)
        self.head_ = start + n
        return body
    }

    fn send(self, const body: string) {
        var msg = f"Content-Length: {body.size()}\r\n\r\n"
        msg += body
        var off: usize = 0
        while off < msg.size() {
            var w: i64 = unsafe kals_stdout_write(unsafe &msg.raw()[off], (msg.size() - off) as u64)
            if w <= 0 {
                self.closed = true
                return
            }

            off += w as usize
        }
    }

    /// Offset of the first body byte of the frame at head_, or usize::MAX
    /// while the header block is incomplete.
    priv fn body_start_(const self) -> usize {
        var i = self.head_
        while (i + 3) < self.buf_.size() {
            if (self.buf_[i] == 13) && (self.buf_[i + 1] == 10) && (self.buf_[i + 2] == 13) && (self.buf_[i + 3] == 10) {
                return i + 4
            }

            i += 1
        }

        return usize::MAX
    }

    /// Body length of the frame at head_ when it is fully buffered, else
    /// usize::MAX.
    priv fn frame_len_(const self) -> usize {
        var start = self.body_start_()
        if start == usize::MAX {
            return usize::MAX
        }

        // Headers are ASCII lines; Content-Length is the only one that
        // matters (Content-Type is optional and always utf-8).
        var name = "content-length:"
        var len: usize = usize::MAX
        var i = self.head_
        while i < start {
            var m: usize = 0
            while (m < name.size()) && ((i + m) < start) {
                var c = self.buf_[i + m]
                if (c >= 65) && (c <= 90) {
                    c = c + 32
                }

                if c != name[m] {
                    break
                }

                m += 1
            }

            if m == name.size() {
                var j = i + m
                while (j < start) && (self.buf_[j] == 32) {
                    j += 1
                }

                var v: usize = 0
                while (j < start) && (self.buf_[j] >= 48) && (self.buf_[j] <= 57) {
                    v = (v * 10) + ((self.buf_[j] - 48) as usize)
                    j += 1
                }

                len = v
                break
            }

            // next header line
            while (i < start) && (self.buf_[i] != 10) {
                i += 1
            }

            i += 1
        }

        if len == usize::MAX {
            // A header block with no length cannot be framed. Treat it as an
            // empty message so the stream moves on instead of stalling.
            return 0
        }

        if (start + len) > self.buf_.size() {
            return usize::MAX
        }

        return len
    }
}
