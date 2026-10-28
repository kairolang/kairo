// A generic panicking function and a generic interface's requirement
// declared in one TU (Inputs/generics_tu/lib.k) and instantiated only in
// its importer (PANIC.md P10): the instances' facts -- each result at its
// arguments, the `__kairo_tid` of every element -- are the importer's to
// form (M2, PanicInstances), and lib.k's template orders each instance's
// set in C++ (`__kairo_pset`), one of them collapsing two elements into
// one (pick at T = Oops). Run at -O0 and -O2.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d %t.o2
// RUN: cd %S/Inputs/generics_tu && %kairo app.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: cd %S/Inputs/generics_tu && %kairo app.k -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
