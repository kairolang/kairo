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
///
/// Only the public C++ API is used (`reserve`, `emplace_back`, `emplace`,
/// the iterator-pair constructor), so any standard library works, and no
/// buffer crosses: Kairo blocks carry a header and come from the Kairo
/// allocator, C++ containers use their own.
///
/// A map or set keeps insertion order; `std::unordered_map` and
/// `std::unordered_set` do not, so the order is lost on the C++ side.

import base::copy::*
import base::hash::*
import base::intrinsics::*
import containers::hash_map::*
import containers::hash_set::*
import containers::slice::*
import containers::vector::*

// An element crosses as a place, `out.emplace_back(*p)`: a move-only `T`
// is moved by that once, and a trivially copyable one copied as cheaply. A
// `T` with a C++ copy constructor of its own would be copied that way, so
// it goes through `move(*p)`, which costs a second move and no copy.
priv eval fn <T> cxx_copies_() -> bool {
    return __builtin_is_constructible<T, const T>() && !__builtin_is_trivially_copyable<T>()
}

// COMPILER-WORKAROUND(dependent-size-type): in a generic body, `out.reserve(n)`
// on a C++ container spells the conversion of the usize argument to
// `size_type` with the class template's own parameter names (`_Key`), which
// clang rejects. An argument that already has the C++ `size_type` is passed
// as it is, so each reservation is written `out.reserve(out.size() + n)`
// on a container just built empty.

extend <T> Vector<T> requires __builtin_is_declared<cxx::std::vector>() {
    pub fn into_cxx(self) -> cxx::std::vector<T> {
        var n = self.len_()
        if n == 0 {
            return cxx::std::vector<T>()
        }

        var unsafe *b = self.base_()
        // Length first: from here the elements belong to the C++ vector, and
        // a trap while they cross leaks rather than destroying one twice.
        self.set_len_(0)
        eval if __builtin_is_trivially_copyable<T>() {
            unsafe {
                return cxx::std::vector<T>(
                    b as unsafe *const T,
                    (b + n) as unsafe *const T,
                )
            }
        } else {
            var out = cxx::std::vector<T>()
            out.reserve(out.size() + n) // COMPILER-WORKAROUND(dependent-size-type)
            unsafe {
                for var i: usize = 0; i < n; ++i {
                    eval if cxx_copies_<T>() {
                        out.emplace_back(move(*(b + i)))
                    } else {
                        out.emplace_back(*(b + i))
                    }

                    __builtin_destruct_at((b + i) as *T)
                }
            }

            return out
        }
    }
}

extend <T impl Copyable> Vector<T> requires __builtin_is_declared<cxx::std::vector>() {
    pub fn op as (const self) -> cxx::std::vector<T> {
        var n = self.len_()
        if n == 0 {
            return cxx::std::vector<T>()
        }

        var unsafe *b = self.base_()
        eval if __builtin_is_trivially_copyable<T>() {
            unsafe {
                return cxx::std::vector<T>(
                    b as unsafe *const T,
                    (b + n) as unsafe *const T,
                )
            }
        } else {
            var out = cxx::std::vector<T>()
            out.reserve(out.size() + n) // COMPILER-WORKAROUND(dependent-size-type)
            unsafe {
                for var i: usize = 0; i < n; ++i {
                    out.emplace_back(copy(*(b + i)))
                }
            }

            return out
        }
    }
}

// Both map forms need std::hash<K> and == on K in C++.
extend <K impl Hash, V> HashMap<K, V> requires __builtin_is_declared<cxx::std::unordered_map>() {
    pub fn into_cxx(self) -> cxx::std::unordered_map<K, V> {
        var n = self.size()
        if n == 0 {
            return cxx::std::unordered_map<K, V>()
        }

        var out = cxx::std::unordered_map<K, V>()
        out.reserve(out.size() + n) // COMPILER-WORKAROUND(dependent-size-type)
        unsafe {
            var unsafe *e = self.entries().first_() as unsafe *MapEntry<K, V>
            for var i: usize = 0; i < n; ++i {
                // COMPILER-WORKAROUND(field-place-move): a field reached through
                // a pointer is passed to C++ as an lvalue (a copy); a whole
                // `*p` is passed as an xvalue (a move).
                var unsafe *k = &(e + i)->key as unsafe *K
                var unsafe *v = &(e + i)->value as unsafe *V
                eval if cxx_copies_<K>() || cxx_copies_<V>() {
                    out.emplace(move(*k), move(*v))
                } else {
                    out.emplace(*k, *v)
                }
            }
        }

        // The moved-from entries are destroyed here, once each.
        self.clear()
        return out
    }
}

extend <K impl Hash, V impl Copyable> HashMap<K, V> requires __builtin_is_declared<cxx::std::unordered_map>() && K impl Copyable {
    pub fn op as (const self) -> cxx::std::unordered_map<K, V> {
        var n = self.size()
        if n == 0 {
            return cxx::std::unordered_map<K, V>()
        }

        var out = cxx::std::unordered_map<K, V>()
        out.reserve(out.size() + n) // COMPILER-WORKAROUND(dependent-size-type)
        unsafe {
            var unsafe *e = self.entries().first_()
            for var i: usize = 0; i < n; ++i {
                out.emplace(copy(e[i].key), copy(e[i].value))
            }
        }

        return out
    }
}

// Both set forms need std::hash<T> and == on T in C++.
extend <T impl Hash> HashSet<T> requires __builtin_is_declared<cxx::std::unordered_set>() {
    pub fn into_cxx(self) -> cxx::std::unordered_set<T> {
        var n = self.size()
        if n == 0 {
            return cxx::std::unordered_set<T>()
        }

        var out = cxx::std::unordered_set<T>()
        out.reserve(out.size() + n) // COMPILER-WORKAROUND(dependent-size-type)
        unsafe {
            var unsafe *p = self.items().first_() as unsafe *T
            for var i: usize = 0; i < n; ++i {
                eval if cxx_copies_<T>() {
                    out.insert(move(*(p + i)))
                } else {
                    out.insert(*(p + i))
                }
            }
        }

        // The moved-from elements are destroyed here, once each.
        self.clear()
        return out
    }
}

extend <T impl Hash> HashSet<T> requires __builtin_is_declared<cxx::std::unordered_set>() && T impl Copyable {
    pub fn op as (const self) -> cxx::std::unordered_set<T> {
        var n = self.size()
        if n == 0 {
            return cxx::std::unordered_set<T>()
        }

        var out = cxx::std::unordered_set<T>()
        out.reserve(out.size() + n) // COMPILER-WORKAROUND(dependent-size-type)
        unsafe {
            var unsafe *p = self.items().first_()
            eval if __builtin_is_trivially_copyable<T>() {
                out.insert(p, p + n)
            } else {
                for var i: usize = 0; i < n; ++i {
                    out.emplace(copy(p[i]))
                }
            }
        }

        return out
    }
}
