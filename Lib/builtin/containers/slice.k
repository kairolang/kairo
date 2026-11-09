/// --- The Kairo Project --------------- Lib/builtin/containers/slice.k --- ///
///
///   The Slice lang item: `[T;]`. Layouts are the ABI; bodies live in std
///   and the runtime. `[T; N]` stays a structural array, and is the type
///   of a `[...]` literal with no container target.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import base::range::*

/// A non-owning view over `len` contiguous elements. `[T;]` is `Slice<T>`, and a `[...]` literal
/// takes this type against a `[T;]` target. A `[T]` converts to it implicitly, with nothing copied.
///
/// The view does not keep its elements alive and does not own them; it is a pointer and a length.
///
/// \see Vector
pub struct <T> Slice {
    /// Pointer to the first element.
    var data: *T
    /// Number of elements in the view.
    var len:  usize

    /// Creates a view of `len` elements starting at `data`.
    ///
    /// No checking: `data` must point at `len` live elements.
    fn Slice(self, data: *T, len: usize) {
        self.data = data
        self.len  = len
    }

    /// Returns the element at index `i` as a place, so `s[i] = x` assigns through the view.
    ///
    /// \note This operator does no bounds check of its own (it indexes the pointer);
    /// `Vector`'s `[]` does.
    pub inline fn op [] (const self, i: usize) -> *T {
        return &self.data[i]
    }

    /// Returns the sub-view `s[a..b]` or `s[a..=b]`. A view: nothing is copied. O(1).
    ///
    /// \panics when `a > b` or the end is past `len` (traps; for `a..=b`, `b >= len`).
    pub inline fn op [] (const self, r: Range<usize>) -> [T;] {
        var hi = r.end
        if r.inclusive {
            if r.end >= self.len { __builtin_trap() }
            hi = r.end + 1
        }
        if (r.begin > hi) || (hi > self.len) { __builtin_trap() }
        return Slice<T>(&self.data[r.begin], hi - r.begin)
    }

    /// Returns the sub-view `s[a..]`; `s[..]` is the whole view. O(1).
    ///
    /// \panics when `a > len` (traps).
    pub inline fn op [] (const self, r: RangeFrom<usize>) -> [T;] {
        if r.begin > self.len { __builtin_trap() }
        return Slice<T>(&self.data[r.begin], self.len - r.begin)
    }

    /// Returns the sub-view `s[..b]` or `s[..=b]`. O(1).
    ///
    /// \panics when the end is past `len` (traps; for `..=b`, `b >= len`).
    pub inline fn op [] (const self, r: RangeTo<usize>) -> [T;] {
        var hi = r.end
        if r.inclusive {
            if r.end >= self.len { __builtin_trap() }
            hi = r.end + 1
        }
        if hi > self.len { __builtin_trap() }
        return Slice<T>(self.data, hi)
    }
}
