#pragma once
namespace pc {
struct Node { int k = 1; };
template <class T> struct Opt { T* p = nullptr; };
template <class T> bool operator!=(const Opt<T>& a, const Opt<T>& b) { return a.p != b.p; }
template <class T> bool operator==(const Opt<T>& a, decltype(nullptr)) { return a.p == nullptr; }
inline Node* find(int) { return nullptr; }
}
