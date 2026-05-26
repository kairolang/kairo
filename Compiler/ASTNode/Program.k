import ASTNode::Casting::*;
import Memory::ArenaList::*;
import AST::ASTContext::*;


enum TopLevelKind derives u8 {
    Decl,
    Stmt,
    Expr,
}

class TopLevelItem {
    pub var kind:  TopLevelKind;
    pub var ptr:   obs::<void>;

    fn TopLevelItem(self, kind: TopLevelKind, ptr: obs::<void>) {
        self.kind = kind;
        self.ptr  = ptr;
    }
    
    static fn from_decl(decl: *Decl) -> TopLevelItem {
        return TopLevelItem(TopLevelKind::Decl, reinterpret_cast::<*void>(decl));
    }

    static fn from_stmt(stmt: *Stmt) -> TopLevelItem {
        return TopLevelItem(TopLevelKind::Stmt, reinterpret_cast::<*void>(stmt));
    }

    static fn from_expr(expr: *Expr) -> TopLevelItem {
        return TopLevelItem(TopLevelKind::Expr, reinterpret_cast::<*void>(expr));
    }

    inline fn as_decl(self) -> *Decl {
        assert(self.kind == TopLevelKind::Decl);
        return reinterpret_cast::<*Decl>(self.ptr);
    }

    inline fn as_stmt(self) -> *Stmt {
        assert(self.kind == TopLevelKind::Stmt);
        return reinterpret_cast::<*Stmt>(self.ptr);
    }

    inline fn as_expr(self) -> *Expr {
        assert(self.kind == TopLevelKind::Expr);
        return reinterpret_cast::<*Expr>(self.ptr);
    }

    inline fn get_kind(self) -> TopLevelKind {
        return self.kind;
    }

    inline fn get_range(self) -> SourceRange {
        switch self.kind {
            case TopLevelKind::Decl { return self.as_decl()->range; }
            case TopLevelKind::Stmt { return self.as_stmt()->range; }
            case TopLevelKind::Expr { return self.as_expr()->range; }
        }
        
        return SourceRange::invalid();
    }
}

class Program {
    pub var items:    ArenaList::<TopLevelItem>;
    pub var ctx:      obs::<ASTContext>;
    pub var fid:      usize; // file id assigned by SourceManager

    fn Program(self, fid: u32, ctx: *ASTContext) {
        self.items.set_allocator(&(ctx->nodes)); // 256 is a reasonable default slab
        self.ctx      = ctx;
        self.fid      = fid;
    }

    fn get_filename(self) -> string {
        return self.ctx->sm->get_filename(self.fid);
    }

    fn add_item(self, item: TopLevelItem) {
        self.items.push(item);
    }
}