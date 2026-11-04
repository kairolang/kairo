#pragma once
struct Base { int k = 1; virtual ~Base() {} };
struct Leaf : Base { int leaf() const { return 7; } };
template <class To, class From> inline decltype(auto) my_cast(From* p) { return static_cast<To*>(p); }
template <class To, class From> inline auto my_ccast(const From* p) { return static_cast<const To*>(p); }
