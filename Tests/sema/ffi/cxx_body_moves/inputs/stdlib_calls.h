#pragma once
#include <istream>
#include <string>

// Declared only: no body to inspect.
template <class S> void hidden(S &in);

// Hands its stream to std::getline, whose body no imported header holds.
template <class S> void read_line(S &in) {
    std::string s;
    std::getline(in, s);
}

// Hands it to std::getline first and then to a function with no body.
template <class S> void read_and_hide(S &in) {
    std::string s;
    std::getline(in, s);
    hidden(in);
}
