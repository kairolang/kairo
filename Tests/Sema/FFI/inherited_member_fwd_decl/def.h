#pragma once
#include "decl.h"
template <class T> struct Common { unsigned size() const { return 1; } T *data(); };
template <class T> struct Impl : Common<T> { void push_back(const T &); };
template <class T, unsigned N> class Buf : public Impl<T> { public: bool own(); };
template <unsigned N> class Str : public Buf<char, N> {};
