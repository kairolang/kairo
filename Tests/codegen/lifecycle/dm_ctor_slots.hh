// dm_ctor_slots.hh -- a C++ type with a counting destructor, held by a
// Kairo class in dm_ctor_slots.k.
#pragma once

inline int dm_cxx_dtors = 0;

struct DmCxx {
    int id;
    DmCxx() noexcept : id(0) {}
    explicit DmCxx(int i) noexcept : id(i) {}
    DmCxx(DmCxx&& o) noexcept : id(o.id) { o.id = 0; }
    DmCxx& operator=(DmCxx&& o) noexcept { id = o.id; o.id = 0; return *this; }
    ~DmCxx() { dm_cxx_dtors += 1; }
};

// The calls since the last read.
inline int dm_cxx_count() noexcept {
    int n = dm_cxx_dtors;
    dm_cxx_dtors = 0;
    return n;
}
