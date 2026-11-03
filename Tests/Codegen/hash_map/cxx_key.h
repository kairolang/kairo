// A C++ key type with a std::hash specialization and an operator==, as a
// C++ program would key a std::unordered_map with it (hash_map/cxx_keys.k).
#pragma once
#include <cstddef>
#include <functional>
#include <string>

struct CxxKey {
    int a;
    int b;
    bool operator==(const CxxKey&) const = default;
};

template <> struct std::hash<CxxKey> {
    std::size_t operator()(const CxxKey& k) const noexcept {
        return std::size_t(k.a) * 1000003u ^ std::size_t(k.b);
    }
};

inline CxxKey make_key(int a, int b) { return CxxKey{a, b}; }
inline std::string make_str(int n) { return std::string(std::size_t(n), 'x'); }
