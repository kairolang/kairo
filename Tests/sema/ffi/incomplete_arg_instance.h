#include "llvm/ADT/DenseMap.h"
namespace ns {
class Fwd;   // never defined: like clang::GlobalDecl in ASTContext.h
struct Ctx { int x; llvm::DenseMap<Fwd, int> m; };
Ctx mk();
}
