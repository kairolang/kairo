#pragma once
// A stack-only buffer: copy and move constructors deleted.
template <typename T, unsigned N>
class Pinned {
    T buf[N]{};
    unsigned n = 0;

  public:
    Pinned() = default;
    Pinned(const Pinned &) = delete;
    Pinned &operator=(const Pinned &) = delete;
    Pinned(Pinned &&) = delete;
    Pinned &operator=(Pinned &&) = delete;
    void push_back(T v) { buf[n++] = v; }
    unsigned size() const { return n; }
    bool is_empty() const { return n == 0; }
    const T &operator[](unsigned i) const { return buf[i]; }
};
