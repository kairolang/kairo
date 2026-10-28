// Overload sets C++ tells apart only by substitution failure, one per
// place SFINAE can sit. Each pair returns a different number, so a run
// test sees which one the call bound.
#pragma once
#include <type_traits>
#include <utility>

struct Pair {
    int a = 0, b = 0;
    Pair() = default;
    Pair(int x, int y) : a(x), b(y) {}
};

// An array type a Kairo file cannot spell itself (`[T;]` is a slice).
using IntArr = int[];
using IntArr3 = int[3];

// 1. enable_if on a defaulted (non-type) template parameter -- libc++'s
//    make_unique shape.
template <class T, std::enable_if_t<std::is_integral_v<T>, int> = 0>
int on_default(T) { return 1; }
template <class T, std::enable_if_t<std::is_floating_point_v<T>, int> = 0>
int on_default(T) { return 2; }

// 2. enable_if on the return type.
template <class T>
std::enable_if_t<std::is_integral_v<T>, int> on_return(T) { return 10; }
template <class T>
std::enable_if_t<std::is_floating_point_v<T>, int> on_return(T) { return 20; }

// 3. enable_if on a function parameter (a defaulted pointer).
template <class T>
int on_param(T, std::enable_if_t<std::is_integral_v<T>>* = nullptr) { return 100; }
template <class T>
int on_param(T, std::enable_if_t<std::is_floating_point_v<T>>* = nullptr) { return 200; }

// 4. enable_if on a defaulted TYPE parameter (the `typename = ...` form).
template <class T, class = std::enable_if_t<std::is_signed_v<T>>>
int on_type_default(T, int) { return 1000; }
template <class T, class = std::enable_if_t<std::is_unsigned_v<T>>>
int on_type_default(T, long) { return 2000; }

// 5. expression SFINAE: decltype on the return type, and void_t.
template <class T>
auto has_size(const T& t) -> decltype(t.size(), int()) { return static_cast<int>(t.size()); }
template <class T>
auto has_size(const T&) -> decltype(std::declval<T>() + 1, int()) { return -1; }

template <class T, class = void> struct has_a : std::false_type {};
template <class T> struct has_a<T, std::void_t<decltype(std::declval<T>().a)>> : std::true_type {};
template <class T, std::enable_if_t<has_a<T>::value, int> = 0>
int field_a(const T& t) { return t.a; }
template <class T, std::enable_if_t<!has_a<T>::value, int> = 0>
int field_a(const T&) { return -7; }

struct Sized {
    int n = 3;
    int size() const { return n; }
};

// 6. a C++20 requires-clause pair.
template <class T> requires std::is_integral_v<T>
int req(T) { return 5; }
template <class T> requires (!std::is_integral_v<T>)
int req(T) { return 6; }

// 7. an explicit template argument decides: like make_unique<T>, nothing
//    deduces T, so only the enable_if tells the two apart.
template <class T, std::enable_if_t<!std::is_array_v<T>, int> = 0>
int kind_of(int) { return 1; }
template <class T, std::enable_if_t<std::is_unbounded_array_v<T>, int> = 0>
int kind_of(int) { return 2; }
template <class T, std::enable_if_t<std::is_bounded_array_v<T>, int> = 0>
int kind_of(int) { return 3; }

// 8. one template only, so a call it does not fit has one candidate.
template <class T, std::enable_if_t<std::is_integral_v<T>, int> = 0>
T twice(T v) { return v * 2; }

// 10. operators found through the operand's namespace, beside a Kairo
//     operator for the same operands (mixed_set.k).
namespace adl {
struct Box { int v = 0; };
template <class T, std::enable_if_t<std::is_integral_v<T>, int> = 0>
int operator+(Box, T) { return 1; }
template <class T, std::enable_if_t<std::is_floating_point_v<T>, int> = 0>
int operator+(Box, T) { return 2; }
}

// 9. by reference: a forwarding parameter whose enable_if reads the
//    DEDUCED reference kind. Only an lvalue makes T a reference.
template <class T, std::enable_if_t<std::is_lvalue_reference_v<T>, int> = 0>
int lval_only(T&&) { return 1; }
template <class T, std::enable_if_t<!std::is_lvalue_reference_v<T>, int> = 0>
int lval_only(T&&) { return 2; }

// 11. one constrained template: a call it does not fit says why.
template <class T> requires std::is_integral_v<T>
int only_int(T) { return 1; }
