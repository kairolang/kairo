#pragma once
template <unsigned N> struct SF { int v = N; SF() {} SF(SF &&o) noexcept : v(o.v) {} SF &operator=(SF &&o) noexcept { v = o.v; return *this; } };
struct Plain { int x = 0; };
