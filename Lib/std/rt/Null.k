module Std {
type CXXNullptrType = typeof &null;

// FIXME type spefieicer is not working for generics
struct <R, ...A> CoroutineTraits {
    type PromiseType = R::PromiseType
}

// TODO: add @always_safe attribute
class <P = void> CoroutineHandle {
  priv var __f: unsafe *void = &null

  eval fn CoroutineHandle(self) = default
 
  @copy // kairo handles the copy constructor and assignment operator for us
  eval fn CoroutineHandle(self, _: CXXNullptrType) {
    self.__f = &null
  }

  static eval fn from_address(self, __a: unsafe *void) -> CoroutineHandle {
    var __h: CoroutineHandle
    __h.__f = __a
    
    return __h
  }

  static fn from_promise(self, __p: core::ref<P>) -> CoroutineHandle {
    var __h: CoroutineHandle
    __h.__f = __builtin_coro_promise(
      __builtin_addressof(__p) as unsafe *void,
      alignof P,
      true
    )
    
    return __h
  }

  eval fn address(const self) -> unsafe *void {
    return self.__f
  }

  eval fn op as (const self) -> bool {
    return self.__f != &null
  }

  fn done(const self) -> bool {
    return __builtin_coro_done(self.__f)
  }

  fn resume(const self) -> void {
    __builtin_coro_resume(self.__f)
  }

  fn destroy(const self) -> void {
    __builtin_coro_destroy(self.__f)
  }

  fn op () (const self) -> void {
    self.resume()
  }

  fn promise(const self) -> core::ref<P> {
    return *(__builtin_coro_promise(
        self.__f,
        alignof P,
        false
      ) as *P)
  }

  eval fn op as (const self) -> CoroutineHandle<void> /* out-of-line */
};

// [coroutine.handle] void specialization.
// MANDATORY: the primary's from_promise(_P&) signature is a hard error when
// _P = void. Signatures instantiate eagerly; bodies do not.
// TODO: add @always_safe attribute
class <> CoroutineHandle<void> {
  priv var __f: unsafe *void = &null

  eval fn CoroutineHandle(self) = default

  @copy // kairo handles the copy constructor and assignment operator for us
  eval fn CoroutineHandle(self, _: CXXNullptrType) {
    self.__f = &null
  }

  static eval fn from_address(__a: unsafe *void) -> CoroutineHandle<void> {
    var __h: CoroutineHandle<void>
    __h.__f = __a

    return __h
  }

  eval fn address(const self) -> unsafe *void {
    return self.__f
  }

  eval fn op as (const self) -> bool {
    return self.__f != &null
  }

  fn done(const self) -> bool {
    return __builtin_coro_done(self.__f)
  }

  fn resume(const self) -> void {
    __builtin_coro_resume(self.__f)
  }

  fn destroy(const self) -> void {
    __builtin_coro_destroy(self.__f)
  }

  fn op () (const self) -> void {
    self.resume()
  }
}

} // namespace std
