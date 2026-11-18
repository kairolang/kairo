#pragma once
// A record with a base and a non-trivial member and no constructor of its
// own, like clang::Expr::EvalResult. Clang declares its default constructor
// lazily, only when something looks one up.
struct Status { bool a; };
struct Payload { int x; Payload() : x(7) {} Payload(const Payload&) = default; };
struct Result : Status { Payload v; };
