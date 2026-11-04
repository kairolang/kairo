// llvm::sys::path::begin: declared a friend of the class first, then at
// namespace scope. The namespace declaration makes it an ordinary member.
namespace ns { namespace sub {
class it { public: int x; friend it begin(const char*, int style); };
it begin(const char* p, int style = 0);
inline it begin(const char* p, int style) { it r; r.x = (int)p[0] + style; return r; }
} }
