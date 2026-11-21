// dm_trait.hh -- a C++ type with a destructor, held by a Kairo class in
// dm_trait.k.
#pragma once

struct DmTraitCxx {
    int id = 0;
    ~DmTraitCxx() {}
};
