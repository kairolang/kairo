// Objective-C++.
@class Widget;
template <class T> T twice(T x) { return x + x; }
int objcxx_ok() { return twice(21); }
