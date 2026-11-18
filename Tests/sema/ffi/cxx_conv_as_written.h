#pragma once
// fmt's format_string shape. The parameter is an alias over the pack
// (opaque to Kairo until clang substitutes T...), built from the literal by
// a consteval constructor, so the literal must reach it as written.
template <class... T> struct fstr {
    int n;
    using t = fstr;
    template <class S> consteval fstr(const S& s) : n(0) { while (s[n]) ++n; }
};
template <class... T> using fs = typename fstr<T...>::t;

// What an argument deduces as: 100 for a class (a builtin::string
// temporary would land here), 1 for anything else (a C string or array).
template <class T> struct kind { static constexpr int v = __is_class(__remove_cvref(T)) ? 100 : 1; };

template <class... T> int pr(fs<T...> f, T&&... a) { return f.n + (0 + ... + kind<T>::v); }
template <class T> int one(const T& m) { return kind<T>::v; }

// A C++ object to a parameter class through a converting constructor.
struct Src { int v; Src(int x) : v(x) {} };
struct Dst { int v; Dst(const Src& s) : v(s.v + 1) {} };
inline int takes_dst(Dst d) { return d.v; }
