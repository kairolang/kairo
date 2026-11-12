/// --- The Kairo Project ----------------------------- Native/AddrRanges.hh --- ///
///
///   A sorted set of labelled address ranges: "is this address inside one
///   of these blocks, and whose". A live check builds one from the arena
///   blocks of the trees it replaced (Tooling/LiveCheck.k), to take what
///   points into them out of the build-wide stores before it frees them and
///   to search the heap for what is left (Native/KShims.hh, heap_scan_report).
///
///   WHY C++: the search is a loop over raw words, and the table is read
///   from the allocator's block visitor, a C callback.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_ADDRRANGES_HH__
#define __KAIRO_NATIVE_ADDRRANGES_HH__

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace kairo {

/// Address ranges, each with a label: the arena blocks of a set of trees
/// (a live check's replaced ones), or of the stores that are searched for
/// pointers into them. add(), then seal(), then find().
struct AddrRanges {
    struct Range {
        uintptr_t lo;
        uintptr_t hi; ///< one past
        unsigned  label;
    };
    ::std::vector<Range>         ranges;
    ::std::vector<::std::string> labels;
    uintptr_t                    lo = ~(uintptr_t)0;
    uintptr_t                    hi = 0;

    unsigned label(const ::std::string &name) {
        labels.push_back(name);
        return (unsigned)labels.size() - 1;
    }

    void add(const void *p, size_t n, unsigned label) {
        if (p == nullptr || n == 0) {
            return;
        }

        ranges.push_back({(uintptr_t)p, (uintptr_t)p + n, label});
    }

    void seal() {
        ::std::sort(ranges.begin(), ranges.end(), [](const Range &a, const Range &b) { return a.lo < b.lo; });
        if (!ranges.empty()) {
            lo = ranges.front().lo;
            hi = 0;
            for (const Range &r : ranges) {
                hi = r.hi > hi ? r.hi : hi;
            }
        }
    }

    /// The range holding \p a, or null.
    const Range *find(uintptr_t a) const {
        if (a < lo || a >= hi) {
            return nullptr;
        }

        size_t b = 0, e = ranges.size();
        while (b < e) {
            size_t m = (b + e) / 2;
            if (ranges[m].lo <= a) {
                b = m + 1;
            } else {
                e = m;
            }
        }

        return (b > 0 && a < ranges[b - 1].hi) ? &ranges[b - 1] : nullptr;
    }

    bool has(const void *p) const { return find((uintptr_t)p) != nullptr; }
    size_t size() const { return ranges.size(); }
};

} // namespace kairo

#endif // __KAIRO_NATIVE_ADDRRANGES_HH__
