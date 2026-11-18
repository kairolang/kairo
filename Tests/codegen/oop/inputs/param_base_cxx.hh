#pragma once
// Corpus for codegen/oop/param_base_cxx.k: a C++ action hierarchy in the
// shape of clang's frontend actions. The base runs an action through a
// protected virtual hook; two concrete actions override it.
namespace act {
class Action {
public:
    Action() = default;
    virtual ~Action() = default;
    int run(int x) { return begin(x) ? work(x) : -1; }
    int runs = 0;

protected:
    virtual bool begin(int x) { ++runs; return x >= 0; }
    virtual int work(int x) { return x; }
    int scale = 2;
};

class Doubler : public Action {
protected:
    bool begin(int x) override { return Action::begin(x) && x < 100; }
    int work(int x) override { return x * scale; }
};

class Adder : public Action {
public:
    int bias = 5;

protected:
    int work(int x) override { return x + bias; }
};

inline int drive(Action &a, int x) { return a.run(x); }
} // namespace act
