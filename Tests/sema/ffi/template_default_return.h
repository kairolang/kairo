#pragma once
// Function templates whose return type is a defaulted template parameter
// no argument deduces.
struct Box {
    int v;
    int get() const { return v; }
};
template <class S, class R = Box> R wrap(const S &s) { return R{int(s) + 1}; }
template <class R = Box, class S> R wrap_first(const S &s) { return R{int(s) - 1}; }
// A default naming an earlier parameter.
template <class S, class R = S> R same(const S &s) { return s * 2; }
