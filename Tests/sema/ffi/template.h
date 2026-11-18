// Corpus for template.k: a class template whose instance clang fills, reached
// through a function returning a concrete specialization.
#pragma once

template <typename T>
struct Box {
    T value;
    T get() const { return value; }
};

Box<int> make_box();
