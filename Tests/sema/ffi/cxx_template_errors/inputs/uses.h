#pragma once

// A template whose body needs a member its declaration does not mention.
template <class T> int count_of(const T &t) { return t.count(); }

// A template whose instantiation inside this header fails on its own,
// with no Kairo code on the instantiation chain.
template <class T> struct Never {
    static_assert(sizeof(T) == 0, "Never<T> is never instantiable");
};
inline int header_only() {
    Never<int> n;
    (void)n;
    return 0;
}
