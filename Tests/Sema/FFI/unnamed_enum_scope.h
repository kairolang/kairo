#pragma once
namespace ue { namespace diag { enum { err_a, err_b }; namespace Sub { enum { s_x = 7 }; } } }
struct UC { enum { k_a = 3, k_b }; };
template <int N> struct UT { enum { v = N }; };
template <class T> struct UP { enum { w = 1 }; };
template <> struct UP<int> { enum { w = 2 }; };
