#pragma once
// Corpus for main.k: a CRTP iterator base with a hidden-friend operator==,
// its derived iterator a template NESTED in a class (clang's
// RedeclarableTemplateDecl::SpecIterator over llvm::iterator_adaptor_base).
namespace xr {
template <class Derived, class Wrapped>
struct adaptor_base {
  Wrapped I;
  adaptor_base() = default;
  explicit adaptor_base(Wrapped w) : I(w) {}
  Derived &operator++() { ++I; return *static_cast<Derived *>(this); }
  friend bool operator==(const adaptor_base &L, const adaptor_base &R) { return L.I == R.I; }
  friend bool operator!=(const adaptor_base &L, const adaptor_base &R) { return !(L.I == R.I); }
  int *operator*() const { return *I; }
};
struct Owner {
  template <class E>
  struct Iter : adaptor_base<Iter<E>, int **> {
    Iter() = default;
    explicit Iter(int **p) : adaptor_base<Iter<E>, int **>(p) {}
    int own() const { return 1; }
  };
  template <class E>
  struct Range {
    int **b; int **e;
    Iter<E> begin() { return Iter<E>(b); }
    Iter<E> end() { return Iter<E>(e); }
  };
  Range<int> specs() { return Range<int>{nullptr, nullptr}; }
};
}
