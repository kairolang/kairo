//===----------------------------------------------------------------------===//
// Kairo coroutine prelude
//
// Injected into the token stream AFTER interop includes are preprocessed.
// Emit conditionally based on DepScan flags:
//   saw_new_header       -> skip the align_val_t block
//   saw_coroutine_header -> skip the std::coroutine shim block
// The #if guards below are a stopgap backstop only; DepScan is the real gate.
//
// No libc++, no libstdc++, no libc headers. Clang builtins only.
//===----------------------------------------------------------------------===//

eval if !defined!(_LIBCPP_NEW) && (!defined(_GLIBCXX_NEW)) && !defined(_NEW_) {
module Std {
    enum AlignmentSizeType derives typeof sizeof (typeof 0) {}
}
}

// ---------------------------------------------------------------------------
// std::coroutine_traits / std::CoroutineHandle
//
// Must be at GLOBAL scope in namespace ::std. Clang's Sema does a hardcoded
// qualified lookup here; nothing redirects it.
// ---------------------------------------------------------------------------
eval if defined!(_LIBCPP_COROUTINE)
     || defined!(_LIBCPP___COROUTINE_COROUTINE_HANDLE_H)
     || defined!(_LIBCPP___COROUTINE_COROUTINE_TRAITS_H)
     || defined!(_GLIBCXX_COROUTINE)
     || defined!(_GLIBCXX_COROUTINE_H)
     || defined!(_COROUTINE_) {
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

// Out of line: CoroutineHandle<void> must be complete first.
eval fn <P> CoroutineHandle<P>::op as (const self) -> CoroutineHandle<void> {
  return CoroutineHandle<void>::from_address(__f);
}

} // namespace std

} // coroutine shim guard

// ---------------------------------------------------------------------------
// Kairo runtime hooks provided by the Kairo runtime, not libc.
// ---------------------------------------------------------------------------
extern "C" *void kairo_alloc(decltype(sizeof(0)) __n);
extern "C" void  kairo_free(*void __p, decltype(sizeof(0)) __n) noexcept;
extern "C" *void kairo_alloc_aligned(decltype(sizeof(0)) __n,
                                     decltype(sizeof(0)) __align);
extern "C" void  kairo_free_aligned(*void __p,
                                    decltype(sizeof(0)) __n,
                                    decltype(sizeof(0)) __align) noexcept;
extern "C" [[noreturn]] void kairo_coro_panic() noexcept;

// ---------------------------------------------------------------------------
// namespace kairo the Kairo-owned surface
// ---------------------------------------------------------------------------
namespace kairo {

using __size_t = decltype(sizeof(0));

struct SuspendAlways {
  eval bool await_ready() const noexcept { return false; }
  eval void await_suspend(::std::CoroutineHandle<>) const noexcept {}
  eval void await_resume() const noexcept {}
};

struct SuspendNever {
  eval bool await_ready() const noexcept { return true; }
  eval void await_suspend(::std::CoroutineHandle<>) const noexcept {}
  eval void await_resume() const noexcept {}
};

template <class T> struct Yield;

template <class T>
struct YieldPromise {
  T* _val = &null;

  Yield<T> get_return_object() noexcept;

  // initial_suspend MUST be SuspendAlways lazy generator.
  // final_suspend MUST be SuspendAlways + noexcept otherwise the frame
  // self-destroys and the handle dangles.
  eval SuspendAlways initial_suspend() const noexcept { return {}; }
  eval SuspendAlways final_suspend()   const noexcept { return {}; }

  SuspendAlways yield_value(T& __v) noexcept {
    _val = __builtin_addressof(__v);
    return {};
  }
  SuspendAlways yield_value(T&& __v) noexcept {
    // Temporary lives to the end of the full-expression; the suspend happens
    // inside it, so the value is valid across the suspend.
    _val = __builtin_addressof(__v);
    return {};
  }

  eval void return_void() const noexcept {}
  void unhandled_exception() { ::kairo_coro_panic(); }

  // Yield<T> is not awaitable. Backstop against co_await smuggled in.
  template <class U> void await_transform(U&&) = delete;

  static *void operator new(__size_t __n) { return ::kairo_alloc(__n); }
  static void  operator delete(*void __p, __size_t __n) noexcept {
    ::kairo_free(__p, __n);
  }

  // Over-aligned frames (alignas members, SIMD types).
  static *void operator new(__size_t __n, ::std::align_val_t __a) {
    return ::kairo_alloc_aligned(__n, static_cast<__size_t>(__a));
  }
  static void operator delete(*void __p, __size_t __n,
                              ::std::align_val_t __a) noexcept {
    ::kairo_free_aligned(__p, __n, static_cast<__size_t>(__a));
  }
};

template <class T>
struct Yield {
  using promise_type = YieldPromise<T>;
  using _Handle = ::std::CoroutineHandle<promise_type>;

  explicit Yield(_Handle __h) noexcept : _h(__h) {}

  Yield(Yield&& __o) noexcept : _h(__o._h) { __o._h = &null; }
  Yield& operator=(Yield&& __o) noexcept {
    if (this != __builtin_addressof(__o)) {
      if (_h) _h.destroy();
      _h = __o._h;
      __o._h = &null;
    }
    return *this;
  }

  Yield(const Yield&)            = delete;
  Yield& operator=(const Yield&) = delete;

  // Breaking out mid-iteration lands here. destroy() resumes the frame in
  // destroy mode and runs destructors of everything live at the suspend point.
  ~Yield() { if (_h) _h.destroy(); }

  // Fused: false forever once exhausted. Never resumes a done or null frame.
  bool _advance() noexcept {
    if ((!_h) || _h.done()) return false;
    _h.resume();
    if (_h.done()) { _h.promise()._val = &null; return false; }
    return true;
  }

  T& _current() const noexcept { return *_h.promise()._val; }

  bool _exhausted() const noexcept { return (!_h) || _h.done(); }

private:
  _Handle _h;
};

template <class T>
Yield<T> YieldPromise<T>::get_return_object() noexcept {
  return Yield<T>{
      ::std::CoroutineHandle<YieldPromise>::from_promise(*this)};
}

} // namespace kairo

