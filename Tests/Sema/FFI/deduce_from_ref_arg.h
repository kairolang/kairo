#pragma once
template <typename T> int take_ptr(T *p) { return p ? 1 : 0; }
template <typename T> T take_val(T v) { return v; }
