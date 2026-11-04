#pragma once
struct NB { enum IntType { NoInt = 0, Signed }; struct Inner { int v; }; typedef int Td; };
struct NMid : NB { int pad; };
struct NDer : NMid { int z; };
