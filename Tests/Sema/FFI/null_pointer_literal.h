#pragma once
#include <cstddef>
#include <utility>

struct Target { Target(int *) {} Target(int) {} Target() {} };

// (a) A forwarding reference of a function template: `&null` is a prvalue
// `std::nullptr_t`, forwarded to the constructor that takes a pointer.
template <typename T, typename... Args> T *create(Args &&...args) { return new T(::std::forward<Args>(args)...); }

// (b) A non-template `std::nullptr_t` parameter.
struct OnlyNullptr { OnlyNullptr(std::nullptr_t) {} };
void takes_nullptr(std::nullptr_t);

// nullptr_t beats the pointer overload, as in clang (identity vs conversion).
struct Both { Both(std::nullptr_t) {} Both(int *) {} };

// A pointer parameter still takes it.
void takes_ptr(int *);
