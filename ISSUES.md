issue 1: perf is bad when running compiled stage1 artifact, this is likely due to a broken range coroutine implementation. speeds at arround 5-10s to pass full frontend pipeline on 3 tokens and print them...


------------------------------------------------------------
NEW ISSUE 
------------------------------------------------------------
When running kbld kfmt, the 
```
PS X:\helix-lang> kbld kfmt
[kbld] build.k compilation failed
error: aborting... due to previous errors
warn: function declared 'noreturn' should not return
   -->  at C:\Helix\core\frame_context.k:35:4
 33 | fn std::Panic::FrameContext::crash() {
 34 |     self.handler(self.error);
 35 |     std::crash(std::Error::RuntimeError(" Object \' " + string(self.error->type_info()->name()) + "\' failed to panic."));
    :     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 36 | }

[kbld] build.k failed
```

On compiling without those lines , the issue shifts to the function signature somehow

```
PS X:\helix-lang> kbld kfmt
[kbld] build.k compilation failed
error: aborting... due to previous errors
warn: function declared 'noreturn' should not return
   -->  at C:\Helix\core\frame_context.k:33:0
 31 | }
 32 | 
 33 | fn std::Panic::FrameContext::crash() {
    : ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 34 |     // self.handler(self.error);
 35 |     // std::crash(std::Error::RuntimeError(" Object \' " + string(self.error->type_info()->name()) + "\' failed to panic."));

[kbld] build.k failed
```

This leads to it most probably being a core stage 0 compiler grammar bug


