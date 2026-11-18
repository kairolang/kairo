// The base lives in another file, as a RecursiveASTVisitor does:
// its bodies are scanned for dyn calls from the deriving file's check.
pub class Node { pub var v: i32 }

pub class <D: type> Visitor {
    pub fn dyn(self) -> unsafe *D { return unsafe ((&self) as *D) }
    pub fn walk(self, n: unsafe *Node) { self.dyn()->visit(n) }
    pub fn visit(self, n: unsafe *Node) { }
}
