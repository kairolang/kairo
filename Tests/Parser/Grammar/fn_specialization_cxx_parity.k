// Function specialization follows C++ exactly. What makes a specialization
// *partial* is a free type variable in the pattern, not a structured argument:
//
//   fn <> p<i32>()    full     <=> template <>        bool p<int>()      OK
//   fn <> p<*i32>()   full     <=> template <>        bool p<int*>()     OK
//   fn <T> p<*T>()    partial  <=> template <class T> bool p<T*>()       ERROR
//
// clang rejects only the third, with "function template partial specialization
// is not allowed". Classifying every structured argument as partial would also
// reject the second, which is legal.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
fn <T> p() -> bool = false
fn <> p<i32>()  -> bool = true
fn <> p<*i32>() -> bool = true
