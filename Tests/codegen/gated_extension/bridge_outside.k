// A bridge whose unconditional code uses its own conditional block.
extend string requires __builtin_is_declared<cxx::std::string>() {
    @implicit pub fn op as (const self) -> cxx::std::string {
        return cxx::std::string(self.c_str(), self.size())
    }

    pub fn cxx_size(const self) -> usize {
        var c: cxx::std::string = self      // inside the block: fine
        return c.size()
    }
}

pub fn ungated(const s: string) -> usize { return s.cxx_size() }
