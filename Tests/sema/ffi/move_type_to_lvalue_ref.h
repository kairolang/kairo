#pragma once
#include <memory>
namespace ns {
struct Unit { int v = 5; };
class Base {
  std::unique_ptr<Unit> unit;
public:
  Base() : unit(new Unit()) {}
  virtual ~Base() {}
  virtual int id() const { return 1; }
};
class Mid : public Base {
  std::unique_ptr<Unit> extra;
public:
  Mid() {}
  int id() const override { return 2; }
};
class Leaf : public Mid {
public:
  Leaf(int *p = nullptr) {}
  int id() const override { return 3; }
};
inline int take(Base &a) { return a.id(); }
struct Host { int run(Base &a) { return a.id(); } };
}
