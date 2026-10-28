/// --- The Kairo Project --------------- Lib/builtin/containers/slice.k --- ///
///
///   The Slice lang item: `[T;]`. Layouts are the ABI; bodies live in std
///   and the runtime. `[T; N]` stays a structural array, and is the type
///   of a `[...]` literal with no container target.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import base::range::*

/// A view over N contiguous T. `[T;]`, and the type a `[...]` literal
/// takes against a `[T;]` target.
pub struct <T> Slice {
    var data: *T
    var len:  usize

    fn Slice(self, data: *T, len: usize) {
        self.data = data
        self.len  = len
    }

    pub inline fn op [] (self, i: usize) -> *T {
        return &self.data[i]
    }

    /// `s[a..b]`, `s[a..=b]`. A view: nothing is copied.
    pub inline fn op [] (self, r: Range<usize>) -> [T;] {
        var hi = r.end
        if r.inclusive {
            if r.end >= self.len { __builtin_trap() }
            hi = r.end + 1
        }
        if (r.begin > hi) || (hi > self.len) { __builtin_trap() }
        return Slice<T>(&self.data[r.begin], hi - r.begin)
    }

    /// `s[a..]`, and `s[..]`.
    pub inline fn op [] (self, r: RangeFrom<usize>) -> [T;] {
        if r.begin > self.len { __builtin_trap() }
        return Slice<T>(&self.data[r.begin], self.len - r.begin)
    }

    /// `s[..b]`, `s[..=b]`.
    pub inline fn op [] (self, r: RangeTo<usize>) -> [T;] {
        var hi = r.end
        if r.inclusive {
            if r.end >= self.len { __builtin_trap() }
            hi = r.end + 1
        }
        if hi > self.len { __builtin_trap() }
        return Slice<T>(self.data, hi)
    }
}
