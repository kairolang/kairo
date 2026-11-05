#pragma once
// `new T(a...)`, as Native/Types.hh's kairo::std::create.
namespace mk {
template <class T, class... A> T* make(A&&... a) { return new T(static_cast<A&&>(a)...); }
}
