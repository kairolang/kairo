#pragma once
struct Cell { int v; };
struct ByVal {
    Cell c;
    Cell operator[](unsigned long) const { return c; }
};
