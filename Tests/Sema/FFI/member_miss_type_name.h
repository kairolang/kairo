#pragma once
template <class T> struct basic { int size() const { return 1; } };
using thing = basic<int>;
inline thing make_thing() { return thing(); }
using other = basic<long>;
inline other make_other() { return other(); }
