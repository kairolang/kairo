/// builtin/compat.k
///
/// TEMPORARY. The member names of the four-word library, as deprecated
/// forwarders onto this library's members, so that code written against the
/// old names compiles here with a deprecation warning (SC146W) at each call
/// and can be rewritten in a batch. This file goes away when the last call
/// site is rewritten; nothing in the library may call a member declared
/// here.
///
/// Only names whose meaning is unchanged are forwarded: a pure rename, or a
/// signature that differs mechanically. A name whose behaviour changed
/// (`HashMap::insert`, `string::op []`, `Vector::insert` by pointer, ...) has
/// no forwarder, because a forwarder would hide the change.

import base::copy::*
import base::hash::*
import base::intrinsics::*
import builtin::Null
import containers::hash_map::*
import containers::hash_set::*
import containers::slice::*
import containers::vector::*
import string::*

extend string {
    @deprecated("use size()")
    pub inline fn length(const self) -> usize {
        return self.size()
    }

    @deprecated("use data()")
    pub inline fn as_ptr(const self) -> *const u8 {
        return self.data()
    }

    @deprecated("use is_empty()")
    pub inline fn empty(const self) -> bool {
        return self.is_empty()
    }

    /// `n` bytes from byte `pos`, both clamped to the string, as a string of
    /// its own. A cut inside a multibyte character traps, where the old
    /// member returned invalid UTF-8.
    @deprecated("use s[pos..pos + n] (a view; add .to_owned() to keep it)")
    pub fn subslice(const self, pos: usize, n: usize) -> string {
        var len = self.size()
        var p   = if pos < len => pos else => len
        var k   = if n < len - p => n else => len - p
        if k == 0 {
            return string()
        }

        return self[p..(p + k)].to_owned()
    }
}

extend <T> Vector<T> {
    @deprecated("use push()")
    pub inline fn push_back(self, v: T) {
        self.push(move(v))
    }

    @deprecated("use is_empty()")
    pub inline fn empty(const self) -> bool {
        return self.is_empty()
    }

    /// Traps on an empty vector, as the old member did; `pop()` returns the
    /// element, or null when there is none.
    @deprecated("use pop()")
    pub inline fn pop_back(self) {
        @unlikely
        if self.is_empty() {
            __builtin_trap()
        }

        self.truncate(self.size() - 1)
    }

    /// Traps on an empty vector.
    @deprecated("use v[0], or first() for a nullable pointer")
    pub inline fn front(self) -> *T {
        return &self[0]
    }

    /// Traps on an empty vector.
    @deprecated("use v[v.size() - 1], or last() for a nullable pointer")
    pub inline fn back(self) -> *T {
        return &self[self.size() - 1]
    }
}

extend <K impl Hash, V> HashMap<K, V> {
    @deprecated("use is_empty()")
    pub inline fn empty(const self) -> bool {
        return self.is_empty()
    }

    /// True when `k` was absent and the pair was added; a present key keeps
    /// its value.
    @deprecated("use try_insert(), which returns the value back when the key exists")
    pub inline fn emplace(self, k: K, v: V) -> bool {
        var back = self.try_insert(move(k), move(v))
        return !back?
    }

    /// True when `k` was present.
    @deprecated("use swap_remove(), which returns the removed value")
    pub inline fn erase(self, const k: K) -> bool {
        var old = self.swap_remove(k)
        return old?
    }

    /// True when `k` was present.
    @deprecated("use shift_remove(), which returns the removed value")
    pub inline fn erase_ordered(self, const k: K) -> bool {
        var old = self.shift_remove(k)
        return old?
    }
}

extend <T impl Hash> HashSet<T> {
    @deprecated("use is_empty()")
    pub inline fn empty(const self) -> bool {
        return self.is_empty()
    }

    @deprecated("use swap_remove()")
    pub inline fn erase(self, const x: T) -> bool {
        return self.swap_remove(x)
    }

    @deprecated("use shift_remove()")
    pub inline fn erase_ordered(self, const x: T) -> bool {
        return self.shift_remove(x)
    }
}
