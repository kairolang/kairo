#pragma once
#include <type_traits>

// Viable only when T is deduced as the object type, never a pointer.
template <class T, std::enable_if_t<!std::is_pointer_v<T>, int> = 0>
int touch(T &x) { (void)x; return 4; }
