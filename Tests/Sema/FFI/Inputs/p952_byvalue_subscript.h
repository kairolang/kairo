#pragma once
// C++ `operator[]`s that return BY VALUE (a temporary) beside one
// that returns a reference (a place).
struct P952Tag {
    int v;
    int bump() { return ++v; }
};

struct P952Box {
    P952Tag t{7};
    P952Tag operator[](int) const { return t; }
};

struct P952Int {
    int slot = 4;
    int operator[](int) const { return 5; }
};

struct P952Ref {
    int slot = 4;
    int& operator[](int) { return slot; }
};
