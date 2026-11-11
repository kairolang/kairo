#pragma once
namespace fcl {
struct Cell { int v; };
struct Row {
    Cell cells[2];
    Cell *begin() { return cells; }
    Cell *end() { return cells + 2; }
};
}
