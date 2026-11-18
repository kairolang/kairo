// Conversions from Kairo types to their C++ standard counterparts, for the
// files that have those C++ types. This file imports NO header: each block
// exists only in a file where the path its `requires` clause asks about is
// declared, and `cxx::std::...` in the block is that file's declaration.

extend string requires __builtin_is_declared<cxx::std::string>() {
    @implicit pub fn op as (const self) -> cxx::std::string {
        return cxx::std::string(self.c_str(), self.size())
    }

    pub fn cxx_size(const self) -> usize {
        var c: cxx::std::string = self
        return c.size()
    }
}

extend <T> [T] requires __builtin_is_declared<cxx::std::vector>() {
    @implicit pub fn op as (const self) -> cxx::std::vector<T> {
        var out = cxx::std::vector<T>()
        for var i: usize = 0; i < self.size(); ++i {
            out.push_back(self[i])
        }

        return out
    }
}

// An unconditional extension of the same type in the same file: its scope
// struct is a different one, the same text in every translation unit.
extend string {
    pub fn doubled(const self) -> usize { return self.size() * 2 }
}
