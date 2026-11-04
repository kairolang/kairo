#pragma once
namespace mu {
struct Base { virtual ~Base() {} int x = 0; };
struct Fwd;
Fwd *make_fwd();
}
