import app::other::Derived
pub interface Bad { fn base_v(self) -> i32 }
extend Derived impl Bad {
    fn base_v(self) -> i32 { return self.ctx + self.tag + self.bump() }
}
