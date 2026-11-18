#pragma once
#include <cstddef>
struct Arena { size_t n = 0; size_t size() const { return n; } void push(int){ n++; } };
