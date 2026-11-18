#pragma once
#include <type_traits>
template <typename Fn> class fref;
template <typename Ret, typename... Params>
class fref<Ret(Params...)> {
  Ret (*cb)(long, Params...) = nullptr;
  long callable;
  template <typename C> static Ret cbf(long c, Params... p) { return (*reinterpret_cast<std::remove_reference_t<C>*>(c))(p...); }
public:
  template <typename Callable>
  fref(Callable &&c, std::enable_if_t<!std::is_same<std::remove_cvref_t<Callable>, fref>::value> * = nullptr)
      : cb(cbf<Callable>), callable((long)&c) {}
};
inline int use(fref<int(int, bool)> f) { return 0; }
