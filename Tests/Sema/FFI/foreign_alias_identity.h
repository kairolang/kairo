#pragma once
#include <map>
#include <string>
#include <vector>
// nlohmann's shape. `json` is a default-argument specialization
// with template-template arguments inside an inline namespace, re-exported
// through two aliases in another namespace.
namespace nl {
inline namespace v1 {
template <template <class, class, class...> class ObjectType = std::map,
          template <class, class...> class ArrayType = std::vector,
          class StringType = std::string, class BooleanType = bool>
struct basic_json {
  static basic_json parse(const char *) { return {}; }
  int dump() const { return 7; }
};
} // namespace v1
using json = basic_json<>;
} // namespace nl
namespace api {
namespace detail {
using Json = nl::json;
}
using detail::Json;
struct Completion {
  Json create(Json input) { return input; }
};
inline Completion completion() { return {}; }
} // namespace api
inline nl::json to_json(const char *, unsigned long) { return {}; }
