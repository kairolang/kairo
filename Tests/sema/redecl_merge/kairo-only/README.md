# kairo-only

No C++ analog exists for these, so the expectation is hand-written and the
1:1 rule cannot be checked mechanically. Every file must say why.

Nearest C++ PRECEDENT for the noreturn question is ref-qualifiers, in
clang/test/CXX/over/over.load/p2-0x.cpp: functions with the same
parameter-type-list cannot be overloaded if SOME BUT NOT ALL carry a
ref-qualifier. That is the same shape as a non-parameter property
participating in overloadability, and is the model to follow if Kairo
decides -> ! is such a property.

For constructs that LOWER to C++ (local specialization), the oracle is
different and better: compile the .k, take the emitted C++, and feed it
to clang. That is an emit test, not a parity test -- it belongs beside
the codegen suite, not here.
