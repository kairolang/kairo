#pragma once
// Class templates in a namespace whose static member comes from a base
// that depends on the arguments, as the standard type traits do.
namespace q {
template <class T, T v> struct IC { static inline const T value = v; };
template <class T> struct Size4 : IC<bool, sizeof(T) == 4> {};
template <class T> struct Trivial : IC<bool, __is_trivially_destructible(T)> {};
template <class T> struct Echo : IC<T, 7> {};
}
