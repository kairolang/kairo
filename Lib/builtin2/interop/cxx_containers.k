/// builtin/interop/cxx_containers.k
///
/// `[T]`, `{K: V}` and `{T}` -> their C++ standard counterparts, for files
/// that already have those headers. The other direction needs nothing here:
/// `Vector`'s `ElemRange` constructor, `HashSet::from_range` and
/// `HashMap::from_pairs` take a C++ container as it is.
///
/// Like interop/cxx_string.k this file imports NO header.
///
/// Two forms each, neither implicit:
///   into_cxx()   moves every element out; the Kairo container is left empty
///   as           deep copy; each element is built from its copy()
/// Elements cross as they are: `[string]` becomes `std::vector` of Kairo
/// `string`, not of `std::string` (conversions never chain).

import base::copy::*
import base::hash::*
import base::intrinsics::*
import containers::hash_map::*
import containers::hash_set::*
import containers::vector::*

extend <T> Vector<T> requires __builtin_is_declared<cxx::std::vector>() {
    pub fn into_cxx(self) -> cxx::std::vector<T> {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Copyable> Vector<T> requires __builtin_is_declared<cxx::std::vector>() {
    pub fn op as (const self) -> cxx::std::vector<T> {
        __builtin_trap() // BODY-TODO
    }
}

// Both map forms need std::hash<K> and == on K in C++.
extend <K impl Hash, V> HashMap<K, V> requires __builtin_is_declared<cxx::std::unordered_map>() {
    pub fn into_cxx(self) -> cxx::std::unordered_map<K, V> {
        __builtin_trap() // BODY-TODO
    }
}

extend <K impl Hash, V impl Copyable> HashMap<K, V> requires __builtin_is_declared<cxx::std::unordered_map>() && K impl Copyable {
    pub fn op as (const self) -> cxx::std::unordered_map<K, V> {
        __builtin_trap() // BODY-TODO
    }
}

// Both set forms need std::hash<T> and == on T in C++.
extend <T impl Hash> HashSet<T> requires __builtin_is_declared<cxx::std::unordered_set>() {
    pub fn into_cxx(self) -> cxx::std::unordered_set<T> {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Hash> HashSet<T> requires __builtin_is_declared<cxx::std::unordered_set>() && T impl Copyable {
    pub fn op as (const self) -> cxx::std::unordered_set<T> {
        __builtin_trap() // BODY-TODO
    }
}
