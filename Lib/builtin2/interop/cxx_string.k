/// builtin/interop/cxx_string.k
///
/// `string` -> C++ strings, for files that already have a C++ standard
/// library in their headers. The other direction needs nothing here:
/// `string`'s `ByteRange` constructor takes any C++ string as it is.
///
/// This file imports NO header. Each `cxx::std::` name resolves through the
/// headers of the file that uses the conversion, so a file with no C++
/// string in its headers never sees these extensions and never parses libc++.
///
/// The view is implicit: a pointer and a length, nothing copied. The owning
/// conversion allocates, so it is written out: `s as cxx::std::string`.

import base::intrinsics::*
import string::*

extend string requires __builtin_is_declared<cxx::std::string_view>() {
    @implicit pub fn op as (const self) -> cxx::std::string_view { // valid while self is
        __builtin_trap() // BODY-TODO
    }
}

extend string requires __builtin_is_declared<cxx::std::string>() {
    pub fn op as (const self) -> cxx::std::string { // copies len bytes
        __builtin_trap() // BODY-TODO
    }
}
