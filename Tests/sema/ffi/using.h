// Corpus for using.k: a typedef and an alias declaration, both usable as
// Kairo types, and a function spelled with one.
#pragma once

typedef int my_int;
using Real = double;

my_int twice(my_int v);
