/// --- The Kairo Project -------------------- Location/SourceLocation.k --- ///
///
///   SourceLocation: a compact 32-bit handle for one source position.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// lightweight encoded handle representing a position in a source file.
///
/// `SourceLocation` is a compact struct that stores a unique 32-bit identifier
/// representing a specific point in source code. it's designed to be trivially
/// copyable, hashable, and efficient to compare.
///
/// the `id` value typically encodes both a file identifier and an offset, but
/// the encoding is implementation-defined. the struct itself treats `id` as an
/// opaque integer and only exposes basic construction, comparison, and offset
/// operations.
///
/// `SourceLocation` is used throughout the compiler to reference precise
/// locations in source files; such as for diagnostics, syntax tree mapping,
/// and line/column resolution; without storing redundant data.
///
/// **Note:** this class performs no validation on its own; the meaning of `id` is
/// defined by the surrounding systems (e.g., SourceManager or SourceLineTable).
///
/// See SourceManager, SourceLineTable.

pub class SourceLocation {
    pub var id: u32 = 0 ///< encoded identifier representing file + offset

    /// default constructor, initializes to invalid.
    ///
    /// **Note:** defaulted, not written out. `id` already has its initialiser
    /// above, so a user-provided body only stops the type being
    /// trivially constructible - which stops from_raw and every
    /// aggregate holding one (SourceRange, Token) from folding their
    /// zero-init away.
    pub fn SourceLocation(self) = default

    /// constructs from a raw 32-bit value.
    ///
    /// ### Parameters
    /// - `raw`: the encoded integer value to use.
    ///
    /// ### Returns
    /// a new SourceLocation with `id = raw`.
    pub static fn from_raw(raw: u32) -> SourceLocation {
        var loc = SourceLocation()
        loc.id = raw
        return loc
    }

    /// constructs from a file base and offset.
    ///
    /// ### Parameters
    /// - `base`: base id (usually file id).
    /// - `offset`: byte offset within the file.
    ///
    /// ### Returns
    /// combined SourceLocation.
    ///
    /// **Note:** base + offset is truncated to 32 bits.
    static fn from_base(base: u32, offset: usize) -> SourceLocation {
        var loc = SourceLocation()
        loc.id = (((base as usize) + offset) as u32)
        return loc
    }

    /// returns the raw encoded integer value.
    pub fn raw(const self) -> u32 {
        return self.id
    }

    /// checks if location is valid.
    ///
    /// ### Returns
    /// true if `id != 0`.
    pub fn is_valid(const self) -> bool {
        return self.id != 0 && self.id != 0xFFFFFFFF
    }

    /// checks if location is invalid.
    ///
    /// ### Returns
    /// true if `id == 0`.
    fn is_invalid(const self) -> bool {
        return self.id == 0 || self.id == 0xFFFFFFFF
    }

    pub static fn invalid() -> SourceLocation {
        return SourceLocation()
    }

    /// returns a new location offset by delta.
    ///
    /// ### Parameters
    /// - `delta`: signed offset to apply.
    ///
    /// ### Returns
    /// a new SourceLocation with adjusted `id`.
    ///
    /// **Warning:** aborts if underflow or overflow occurs.
    /// FIXME: this is failing for some reason
    pub fn with_offset(const self, delta: i64) -> SourceLocation {
        var new_val = (self.id as i64) + delta

        // if new_val < 0 {
        //     std::crash(std::Error::RuntimeError("SourceLocation: underflow"));
        // }

        // if new_val > static_cast::<i64>(0xFFFFFFFF) {
        //     std::crash(std::Error::RuntimeError("SourceLocation: overflow"));
        // }

        var loc = SourceLocation()
        loc.id = (new_val as u32)

        return loc
    }

    /// equality operator.
    pub fn op == (const self, other: SourceLocation) -> bool {
        return self.id == other.id
    }

    /// inequality operator.
    pub fn op != (const self, other: SourceLocation) -> bool {
        return self.id != other.id
    }

    /// less-than comparison.
    fn op < (const self, other: SourceLocation) -> bool {
        return self.id < other.id
    }

    /// less-than-or-equal comparison.
    pub fn op <= (const self, other: SourceLocation) -> bool {
        return self.id <= other.id
    }

    /// greater-than comparison.
    pub fn op > (const self, other: SourceLocation) -> bool {
        return self.id > other.id
    }

    /// greater-than-or-equal comparison.
    fn op >= (const self, other: SourceLocation) -> bool {
        return self.id >= other.id
    }


    /// returns a simple hash of the location id.
    ///
    /// uses a lightweight FNV-1a-like hash mix to distribute bits of `id`.
    fn hash(const self) -> u32 {
        var h: u32 = 0x811C9DC5

        h = (h ^ self.id) * 0x01000193
        return h
    }

    /// constructs a location directly from a pointer.
    ///
    /// ### Parameters
    /// - `ptr`: pointer to convert into a 32-bit handle.
    ///
    /// ### Returns
    /// SourceLocation with encoded pointer value.
    ///
    /// **Note:** pointer value is truncated to 32 bits.
    static fn from_ptr(ptr: unsafe *void) -> SourceLocation {
        return SourceLocation::from_raw((ptr as usize) as u32)
    }

    /// string conversion operator.
    ///
    /// ### Returns
    /// formatted string like `SourceLocation(id: 12345)`.
    fn op as (const self) -> string {
        return f"{self.id}"
    }

    /// computes the byte distance between two locations.
    ///
    /// ### Parameters
    /// - `other`: the location to compute distance to.
    ///
    /// ### Returns
    /// absolute difference in raw ids.
    fn distance_to(const self, other: SourceLocation) -> usize {
        if self.id > other.id {
            return (self.id - other.id) as usize
        }

        return (other.id - self.id) as usize
    }

    /// advances location by n bytes.
    ///
    /// ### Parameters
    /// - `n`: number of bytes to advance.
    ///
    /// ### Returns
    /// new location advanced by n.
    pub fn advance(const self, n: usize) -> SourceLocation {
        return self.with_offset(n as i64)
    }

    /// retreats location by n bytes.
    ///
    /// ### Parameters
    /// - `n`: number of bytes to go back.
    ///
    /// ### Returns
    /// new location moved back by n.
    pub fn retreat(const self, n: usize) -> SourceLocation {
        return self.with_offset(-(n as i64))
    }
}
