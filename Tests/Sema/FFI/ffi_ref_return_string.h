#pragma once
// Reference returns of a class type (std::string, which has a destructor),
// overridden and defined in Kairo with `ffi::ref`.
#include <string>
struct Named {
    std::string tag = "base";
    virtual const std::string &name() const { return tag; }
    virtual std::string &label() { return tag; }
    virtual ~Named() = default;
    std::string &slot();
};
inline std::size_t name_len(const Named &n) { return n.name().size(); }
inline void relabel(Named &n) { n.label() = "from-c++"; }
