#pragma once

template <class T>
struct box {
    T v;
    unsigned long size() const { return 1; }
    T* get() { return &v; }
};

box<int>&       lref_box();
const box<int>& cref_box();
box<int>&&      rref_box();
box<int>*&      ptr_ref_box();
