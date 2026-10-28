// partial_spec_header/store.k -- imported by app.k; the specializations its
// header must carry wherever it carries the primary.
pub class <T> Store {
    pub var value: T
    fn Store(self, v: T) { self.value = v }
    pub fn tag(const self) -> i32 = 1
}
pub class <P> Store<*P> {
    priv var ptr: unsafe *P
    fn Store(self, v: *P) { unsafe { self.ptr = v as unsafe *P } }
    pub fn tag(const self) -> i32 = 2
}
pub class <> Store<bool> {
    priv var bits: u8 = 2
    fn Store(self, v: bool) { self.bits = v as u8 }
    pub fn tag(const self) -> i32 = 3
}
extend <> Store<bool> {
    pub fn on(const self) -> bool = self.bits == 1
}
extend <P> Store<*P> {
    pub fn read(const self) -> P {
        unsafe { return *self.ptr }
    }
}
