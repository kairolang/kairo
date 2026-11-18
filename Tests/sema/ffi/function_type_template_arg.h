#pragma once
template <class Fn> struct FRef;
template <class R, class... A> struct FRef<R(A...)> {
  template <class C> FRef(C &&) {}
};
inline void take(FRef<bool(int)>) {}
