//! Zig root of the musl `libc.so` build (build/musl.zig), whose real content is
//! musl's own C sources.
//!
//! It exists to pull Zig's `compiler_rt` into *this* compilation rather than letting
//! Zig link its prebuilt copy: `compiler_rt` exports its symbols hidden unless the
//! compilation it belongs to is itself dynamically linked (see the standard library's
//! `compiler_rt.zig`), and a hidden duplicate of `memcpy`/`strlen`/`memset`/the libm
//! basics would take musl's own definitions of those out of the finished library's
//! dynamic symbol table -- ELF resolves visibility to the most restrictive of all
//! definitions. Compiled here, in the shared library's own compilation, the same
//! symbols come out with default visibility and musl's strong definitions win.
//!
//! What musl actually needs from it: complex multiplication (`src/complex/cpow*.c`)
//! on every target, plus the soft-float long-double helpers on targets where
//! `long double` is IEEE binary128 (aarch64's `fmodl`, `printf`'s long-double path).

comptime {
    _ = @import("compiler_rt");
}
