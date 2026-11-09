/// --- The Kairo Project ----------------------- Location/SourceRange.k --- ///
///
///   SourceRange: a half-open interval between two SourceLocations.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Location::SourceLocation::SourceLocation

///
/// \file SourceRange.k
/// \brief compact representation of a half-open interval between two source
///        locations.
///
/// \details
/// `SourceRange` models a range of text within a single source file, defined by
/// a starting and ending `SourceLocation`. the range is **half-open** - meaning
/// it includes the start position but excludes the end - consistent with how
/// most compiler systems handle spans and slices.
///
/// this structure provides utilities for validation, containment checks,
/// overlap detection, merging, and hashing. it's used throughout the compiler
/// for diagnostics, token spans, and syntax tree mappings.
///
/// `SourceRange` assumes both endpoints are in the same file; it does not
/// perform cross-file validation on its own.
///
/// \note zero-length or invalid ranges are allowed, but considered non-meaningful
/// for operations like merging or containment.
///
/// \see SourceLocation, SourceManager, SourceLineTable
///

pub class SourceRange {
    pub var start: SourceLocation = SourceLocation() ///< inclusive start
    pub var end:   SourceLocation = SourceLocation() ///< exclusive end

    ///
    /// \brief default constructor, initializes to invalid range.
    ///
    pub fn SourceRange(self) = default

    ///
    /// \brief constructs a range directly from its two bounds.
    ///
    /// \details Every factory below used to default-construct - zeroing both
    ///          endpoints - and then immediately overwrite them. That showed up
    ///          as SourceRange::SourceRange() at 13.7% of main-thread self time
    ///          on the 1 GiB lex benchmark, because the lexer builds a range
    ///          for every single token and the constructor was not inlining.
    pub fn SourceRange(self, start: SourceLocation, stop: SourceLocation) {
        self.start = start
        self.end   = stop
    }

    ///
    /// \brief constructs a range from two explicit bounds.
    ///
    /// \param start start location.
    /// \param stop  end location.
    /// \return range covering [start, stop).
    ///
    pub static fn from_bounds(start: SourceLocation, stop: SourceLocation) -> SourceRange {
        return SourceRange(start, stop)
    }

    ///
    /// \brief constructs a range from start location and length.
    ///
    /// \param start start location.
    /// \param len   number of bytes to cover.
    /// \return range covering [start, start+len).
    ///
    pub static fn from_bounds(start: SourceLocation, len: u32) -> SourceRange {
        return SourceRange(start, start.with_offset(len))
    }

    ///
    /// \brief constructs a single-character range.
    ///
    /// \param loc source location to cover.
    /// \return range covering [loc, loc+1).
    ///
    pub static fn single(loc: SourceLocation) -> SourceRange {
        return SourceRange(loc, loc.with_offset(1))
    }

    ///
    /// \brief checks if range is valid.
    ///
    /// \details
    /// a range is valid if both endpoints are valid and `start <= end`.
    ///
    pub fn is_valid(const self) -> bool {
        return self.start.is_valid() && self.end.is_valid() && self.start <= self.end
    }

    ///
    /// \brief checks if range is invalid.
    ///
    pub fn is_invalid(const self) -> bool {
        return !self.is_valid()
    }

    pub static fn invalid() -> SourceRange {
        return SourceRange::from_bounds(SourceLocation::invalid(), SourceLocation::invalid())
    }

    ///
    /// \brief returns the size (in bytes) of the range.
    ///
    /// \return difference between `end` and `start` ids, or 0 if reversed.
    ///
    pub fn size(const self) -> u32 {
        if self.end < self.start {
            return 0
        }

        return self.end.raw() - self.start.raw()
    }

    ///
    /// \brief checks if a location falls within the range.
    ///
    /// \param loc location to test.
    /// \return true if `start <= loc < end`.
    ///
    pub fn contains(const self, loc: SourceLocation) -> bool {
        return loc >= self.start && loc < self.end
    }

    ///
    /// \brief checks if this range overlaps another.
    ///
    /// \param other other range to test.
    /// \return true if intervals intersect.
    ///
    fn overlaps(const self, other: SourceRange) -> bool {
        return self.start < other.end && other.start < self.end
    }

    ///
    /// \brief merges two ranges into their minimal bounding span.
    ///
    /// \param other other range to merge with.
    /// \return merged range covering both.
    ///
    /// \note if one range is invalid, the other is returned unchanged.
    ///
    /// \example merging two ranges:
    /// lets say two ranges: A = [9, 15) and B = [12, 20)
    /// A.merge(B) would return [9, 20) because it covers all of A and B.
    ///
    fn merge(const self, other: SourceRange) -> SourceRange {
        if self.is_invalid() {
            return other
        }

        if other.is_invalid() {
            return self
        }

        return SourceRange(
            if (self.start < other.start) => (self.start) else => other.start,
            if (self.end > other.end) => (self.end) else => other.end,
        )
    }

    ///
    /// \brief equality operator.
    ///
    pub fn op == (const self, other: SourceRange) -> bool {
        return self.start == other.start && self.end == other.end
    }

    ///
    /// \brief inequality operator.
    ///
    fn op != (const self, other: SourceRange) -> bool {
        return !(self == other)
    }

    ///
    /// \brief string conversion operator.
    ///
    /// \return formatted string like `SourceRange(start: <start>, end: <end>)`.
    ///
    fn op as (const self) -> string {
        return f"[{(self.start) as string}, {(self.end) as string})"
    }

    ///
    /// \brief computes a hash for this range.
    ///
    /// \details
    /// mixes both start and end values using FNV-1a-like hashing for
    /// good distribution in hash tables.
    ///
    fn hash(const self) -> u32 {
        var h: u32 = 0x811C9DC5
        h = (h ^ self.start.raw()) * 0x01000193
        h = (h ^ self.end.raw()) * 0x01000193

        return h
    }

    ///
    /// \brief checks if range is empty (zero-length).
    ///
    pub fn is_empty(const self) -> bool {
        return self.start == self.end
    }

    ///
    /// \brief returns a range expanded by n bytes on both sides.
    ///
    /// \param n number of bytes to expand.
    /// \return expanded range.
    ///
    fn expand(const self, n: usize) -> SourceRange {
        return SourceRange(self.start.retreat(n), self.end.advance(n))
    }

    ///
    /// \brief returns a range shrunk by n bytes on both sides.
    ///
    /// \param n number of bytes to shrink.
    /// \return shrunk range (or empty if too small).
    ///
    fn shrink(const self, n: usize) -> SourceRange {
        var lo = self.start.advance(n)
        var hi = self.end.retreat(n)

        return SourceRange(lo, if (lo <= hi) => (hi) else => lo)
    }

    ///
    /// \brief returns the intersection of two ranges.
    ///
    /// \param other range to intersect with.
    /// \return intersecting range, or invalid if no overlap.
    ///
    fn intersect(const self, other: SourceRange) -> SourceRange {
        if !self.overlaps(other) {
            return SourceRange() // invalid
        }

        return SourceRange(
            if (self.start > other.start) => (self.start) else => other.start,
            if (self.end < other.end) => (self.end) else => other.end,
        )
    }

    ///
    /// \brief returns a range from start of this to end of other.
    ///
    /// \param other range to union with.
    /// \return range covering both (may include gap).
    ///
    fn op + (const self, other: SourceRange) -> SourceRange {
        return self.merge(other)
    }

    pub fn op | (const self, other: SourceRange) -> SourceRange {
        return self.merge(other)
    }

    fn op & (const self, other: SourceRange) -> SourceRange {
        return self.intersect(other)
    }

    fn op ~ (const self) -> SourceRange {
        return SourceRange::from_bounds(self.start, self.size())
    }

    fn op - (const self, other: SourceRange) -> SourceRange {
        return self.shrink(other.size() as usize)
    }

    fn op << (const self, n: usize) -> SourceRange {
        return self.expand(n)
    }

    fn op >> (const self, n: usize) -> SourceRange {
        return self.shrink(n)
    }

    fn op < (const self, other: SourceRange) -> bool {
        return self.start < other.start
    }

    fn op <= (const self, other: SourceRange) -> bool {
        return self.start <= other.start
    }

    fn op > (const self, other: SourceRange) -> bool {
        return self.start > other.start
    }

    fn op >= (const self, other: SourceRange) -> bool {
        return self.start >= other.start
    }
}
