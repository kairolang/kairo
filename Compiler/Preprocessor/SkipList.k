/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Token::TokenBuffer::*;
import Location::SourceRange::*;

// =========================================================================
//  SKIP LIST
// =========================================================================

/// \brief sorted list of SourceRange "dead zones" that the expander skips.
///        Populated during import scanning and definition collection.
///        Binary-searched during expansion O(log n) per token.
class SkipList {
    priv var _ranges: vec::<SourceRange>;

    /// \brief registers a dead zone (import statement, macro def, ffi block)
    fn add(self, range: SourceRange) {
        self._ranges.push_back(range);
    }

    /// \brief sorts ranges by start location. Call once after collection is done.
    fn finalize(self) {
        libcxx::sort(self._ranges.begin(), self._ranges.end(),
            fn (a: SourceRange, b: SourceRange) -> bool {
                return a.start.raw() < b.start.raw();
            }
        );
    }

    /// \brief returns true if `loc` falls inside any dead zone
    fn contains(self, loc: SourceLocation) -> bool {
        var raw = loc.raw();
        var lo: usize = 0;
        var hi: usize = self._ranges.size();

        while lo < hi {
            var mid = lo + (hi - lo) / 2;
            var r = self._ranges[mid];

            if raw < r.start.raw() {
                hi = mid;
            } else if raw >= r.end.raw() {
                lo = mid + 1;
            } else {
                return true;
            }
        }

        return false;
    }

    /// \brief returns the index of the first token past the dead zone,
    ///        or `from` if `from` is not in a dead zone.
    fn skip_past_index(self, tokens: *(TokenBuffer::<512>), from: usize) -> usize {
        if from >= tokens->size() { return from; }

        var tok = tokens->get(from);
        var raw = tok->range.start.raw();

        // binary search for the zone
        var lo: usize = 0;
        var hi: usize = self._ranges.size();
        var zone_end_raw: u32 = 0;

        while lo < hi {
            var mid = lo + (hi - lo) / 2;
            var r = self._ranges[mid];

            if raw < r.start.raw() {
                hi = mid;
            } else if raw >= r.end.raw() {
                lo = mid + 1;
            } else {
                zone_end_raw = r.end.raw();
                break;
            }
        }

        if zone_end_raw == 0 { return from; }

        // advance past the dead zone
        var j = from;
        while j < tokens->size() {
            if tokens->get(j)->range.start.raw() >= zone_end_raw {
                return j;
            }
            j += 1;
        }

        return j;
    }

    fn size(self) -> usize {
        return self._ranges.size();
    }

    fn clear(self) {
        self._ranges.clear();
    }

    fn dump(self) {
        std::print(f"=== SkipList Dump ({self._ranges.size()} ranges) ===");
        for var i: usize = 0; i < self._ranges.size(); ++i {
            var r = self._ranges[i];
            std::print(f"  [{i}] start={r.start.raw()} end={r.end.raw()} (span={r.end.raw() - r.start.raw()})");
        }
        std::print("=== End SkipList ===");
    }
}