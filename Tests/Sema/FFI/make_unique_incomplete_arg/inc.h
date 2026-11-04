#pragma once
namespace mi {
// Never defined: like clang::ModuleCache in a set that only forward-declares it.
struct Inc;
struct Gen {
  Gen(Inc &, int, bool = false) {}
  virtual ~Gen() {}
};
Inc &get_inc();
}
