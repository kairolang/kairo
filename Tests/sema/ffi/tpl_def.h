#pragma once
#include "tpl_fwd.h"

template <class T>
class Vec {
public:
    void push(const T& x);
    unsigned long size() const;
};
