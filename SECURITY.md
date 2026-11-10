# Security Policy

## Reporting a vulnerability

Do not open a public issue for a security problem.

Report it privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. The report is visible only to the maintainers.

If you cannot use GitHub, email security@kairolang.org.

Include what you can: the affected version (`kairo --version`), the target, a minimal reproduction, and the impact you expect. You will get an acknowledgement within 7 days, and a fix or a decision through the same private advisory.

There is no bug bounty.

## Disclosure

Please give us 90 days, or until a fix is released, whichever is first, before disclosing publicly. We credit reporters in the advisory unless asked not to.

## What counts

Not security issues (report them as ordinary bugs): the compiler crashing, hanging or using excessive memory on malformed or hostile source code; diagnostics; build failures. Compiling untrusted source is not a supported security boundary.

Security issues include:

- miscompilation that breaks a guarantee the language documents for code outside `unsafe`: a safe pointer (`*T`) that is null or was fabricated without provenance, a nullable (`T?`) accessed without its check, or a list (`[T]`) index that escapes its bounds check;
- vulnerabilities in the runtime or libraries under `Lib/rt/`, `Lib/builtin/` and `Lib/std/`;
- archive extraction (`katar`) escaping its destination;
- `ksys` writing outside its cache or prefix while building a sysroot, or accepting a tampered sysroot input that fails its registry hash;
- installers or release artifacts that can be tampered with.

Kairo 0.2.0 does not yet promise full memory safety for safe code; the guarantees above are the ones it documents and checks today.

## Supported versions

Security fixes go into the latest release line.

| Version | Supported |
|---|---|
| 0.2.x | Yes |
| 0.1.x and earlier (the retired C++ bootstrap) | No |

## Scope

The toolchain (`kairo`, `kcc`, `kld`, `kfmt`, `ksys`, `katar`), the runtime and libraries, the release installers, and the sysroot scripts shipped in releases.

Third-party components (LLVM, mimalloc, musl and the rest listed in `NOTICE`) are in scope where Kairo's build or use of them introduces the problem. Report upstream bugs to their projects as well.
