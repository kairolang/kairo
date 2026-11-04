#pragma once
// Two unscoped enums nested in one class, enumerator values overlapping.
struct K {
  enum A { a0, a1, a2, a3, a4 };
  enum B { b0, b1 };
  B b = b0;
  A a = a0;
  void setB(B v) { b = v; }
  B getB() const { return b; }
  void setA(A v) { a = v; }
  A getA() const { return a; }
};
