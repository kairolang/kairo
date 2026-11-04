#pragma once
namespace ns {
enum class ft { a, b, c };
inline ft get() { return ft::b; }
template <typename T> struct Box {};
template <typename T> bool operator==(Box<T>, Box<T>) { return true; }
}
