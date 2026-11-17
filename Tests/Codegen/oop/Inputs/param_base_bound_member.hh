#pragma once
namespace hb {
struct Base {
    int n = 1;
    int size() { return 1; }
    virtual int kind() { return 10; }
    virtual ~Base() = default;
protected:
    int guard = 5;
};
// Declares again a non-virtual member and a field of the bound: a mixin
// over it still reaches the bound's.
struct Hide : Base {
    int n = 2;
    int size() { return 2; }
    int kind() override { return 20; }
};
}
