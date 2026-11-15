#pragma once
// A header clang counts as a system header that is not the toolchain's
// library: neither its own functions nor what it declares into namespace
// std are the standard library's.
#pragma GCC system_header

namespace tp {
template <class T> void consume(T &x);
}

namespace std {
template <class T> void not_really_std(T &x);
}
