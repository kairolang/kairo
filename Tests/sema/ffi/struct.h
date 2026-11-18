// Corpus for struct.k: a C aggregate and a free function taking it by value.
#pragma once

struct Point {
    int x;
    int y;
};

int point_sum(Point p);
