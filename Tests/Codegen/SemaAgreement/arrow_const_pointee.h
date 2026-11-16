#pragma once

// 1: the const overload ran, 2: the non-const one.
struct Ent {
    int v = 0;
    int which() const { return 1; }
    int which() { return 2; }
};

// The shape of llvm::StringMap's iterators: `operator->` is in a CRTP base
// and its pointee is a template argument that carries the const.
template <class Derived, class V> struct ItBase {
    V *p = nullptr;
    V *operator->() const { return p; }
    V &operator*() const { return *p; }
};
struct CIt : ItBase<CIt, const Ent> {};
struct MIt : ItBase<MIt, Ent> {};

// A const / non-const `operator->` pair, as std::optional has.
struct Opt {
    Ent e;
    const Ent *operator->() const { return &e; }
    Ent *operator->() { return &e; }
};

struct Tab {
    Ent e;
    CIt cbegin() const { CIt i; i.p = &e; return i; }
    MIt begin() { MIt i; i.p = &e; return i; }
};
