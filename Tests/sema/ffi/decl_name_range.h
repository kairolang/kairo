// decl_name_range.k imports this. The last declaration is an inheriting
// constructor, `using BaseT::BaseT;`, whose printed NAME is the base's whole
// specialization -- far longer than the bytes left in this file after it.
#pragma once
template <class ValueT, class MapT, class InfoT>
struct LongNamedBaseImplementation {
    int v = 0;
    LongNamedBaseImplementation() = default;
    LongNamedBaseImplementation(int x) : v(x) {}
    int get() const { return v + 6; }
};
template <class T>
struct Wrapped : LongNamedBaseImplementation<T, LongNamedBaseImplementation<T, T, T>, int> {
  using BaseT = LongNamedBaseImplementation<T, LongNamedBaseImplementation<T, T, T>, int>;
  using BaseT::BaseT;
};
