// Forwarding packs and the other pack patterns a C++ API is written with.
#pragma once
#include <memory>
#include <type_traits>
#include <utility>

struct Pair {
    int a = 0, b = 0;
    Pair() = default;
    Pair(int x, int y) : a(x), b(y) {}
};

// std::make_unique's shape: an explicit T, the constructor's arguments
// forwarded.
template <class T, class... Args> std::unique_ptr<T> make_box(Args&&... args) {
    return std::unique_ptr<T>(new T(std::forward<Args>(args)...));
}
template <class T, class... Args> T make(Args&&... args) { return T(std::forward<Args>(args)...); }

inline int sum_all() { return 0; }
template <class T, class... Rest> int sum_all(T&& t, Rest&&... rest) {
    return static_cast<int>(t) + sum_all(std::forward<Rest>(rest)...);
}
template <class... Ts> int forward_sum(Ts&&... ts) { return sum_all(std::forward<Ts>(ts)...); }

// Non-forwarding patterns: `const Ts&...` binds anything, `Ts&...` only
// lvalues (and writes through them).
template <class... Ts> int count_args(const Ts&...) { return static_cast<int>(sizeof...(Ts)); }
inline void bump_all() {}
template <class T, class... Rest> void bump_all(T& t, Rest&... rest) { t += 1; bump_all(rest...); }

// A defaulted template parameter that is never deduced: C++ fills it.
template <class T, std::enable_if_t<std::is_integral_v<T>, int> = 0> T twice(T v) { return v * 2; }
