#pragma once
// llvm::isa: the pack comes FIRST and the argument's type deduces after it.
template <typename T> struct Is { static bool check(const int &) { return sizeof(T) == 4; } };
template <typename... To, typename From>
inline bool isa(const From &v) { return (Is<To>::check(v) || ...); }
template <typename... To, typename From>
inline int count(const From &) { return sizeof...(To); }
