#pragma once
// Enums in a namespace and at global scope, scoped and not.
namespace ns {
enum class E { a, b };
enum U { u0, u1, u2 };
}
enum class G { g0, g1, g2, g3 };
