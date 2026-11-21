// destructive_moves_unchanged.hh -- a C++ class for
// destructive_moves_unchanged.k: move-only, its move zeroes the source, and
// every destructor call is counted.
#pragma once

inline int dm_cxx_dtors = 0;

struct DmCxx {
    int id;
    DmCxx() : id(0) {}
    explicit DmCxx(int i) : id(i) {}
    DmCxx(DmCxx&& o) noexcept : id(o.id) { o.id = 0; }
    DmCxx(const DmCxx&) = delete;
    DmCxx& operator=(DmCxx&& o) noexcept {
        id   = o.id;
        o.id = 0;
        return *this;
    }
    ~DmCxx() { ++dm_cxx_dtors; }
};

inline int dm_cxx_count() { return dm_cxx_dtors; }
