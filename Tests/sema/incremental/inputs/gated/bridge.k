extend string requires __builtin_is_declared<cxx::std::string>() {
    @implicit pub fn op as (const self) -> cxx::std::string {
        return cxx::std::string(self.c_str(), self.size())
    }
}
