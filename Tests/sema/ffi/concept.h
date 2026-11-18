// Corpus for concept.k: a C++20 concept imports as a constraint-only
// interface; a function template constrained by it imports as a generic.
#pragma once

template <typename T>
concept Addable = requires(T a, T b) { a + b; };

template <Addable T>
T add_twice(T a) { return a + a; }
