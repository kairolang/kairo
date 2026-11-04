#pragma once
#include <memory>
struct Tok { int a; };
namespace kairo { using Arr = Tok[]; }
struct PP { void Enter(std::unique_ptr<Tok[]> p, unsigned n, bool a, bool b); };
