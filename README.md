# build-your-python

A Python library to build the CPython interpreter, in a modular, extensible, and freestanding way.
This project is an alternative build pipeline for CPython, based on the Zig build system.
It can be run in two ways:

* directly from source (this repo) with a Zig compiler (0.17.x), the only mandatory dependency of this package.
* from Python by installing the Python bindings (`pip install build-your-python`). No system dependency needed, it is standalone.

The [manifest](#manifest) below should give deeper insights on the *raison d'être* of this project.<br>
The goals are similar to Astral's [standalone Python](https://github.com/astral-sh/python-build-standalone).
This project however takes the process one step further: it exposes all of CPython's compilation flags and optional behavior as part of a user-controlled interface, and adds cross-compilation support (whereas the Astral project is more CI/CD oriented, its main goal being to produce one single artifact).
The typical use case is integration into tooling that builds standalone binaries out of Python projects, typically to build a custom-tailored interpreter for that project. It provides mostly four things that you do not get from the CPython source itself:

* lightweight build: you only need the Zig compiler (if you install this from PyPI, it is installed automatically for you), which is itself a standalone binary. Nothing else is required.
* standalone build pipelines not only for the interpreter itself but also for most of the 3rd party dependencies it relies on (the exceptions are ncurses, readline and Tcl/Tk, which only support dynamic linking; see [Limitations](#limitations)), so you don't have to dynamically link them, making your interpreter executable truly standalone.
* selecting what goes into your interpreter (i.e., you can include only the subset of the 3rd party libraries mentioned above that you need), and the related options, from one unified top-level interface, controllable directly from Python.
* native cross-compilation support, including for the vendored 3rd party dependencies (see [Limitations](#limitations) for tested targets).

> [!NOTE]
> **Static linking is a default, not a constraint.** Standalone-ness is a core goal, so 3rd party libraries are statically linked by default wherever a vendored build exists. Everything remains modular, though: each library has its own linkage option (`-Dopenssl-linkage`, `-Dzlib-linkage`, `-Dsqlite-linkage`, `-Dbz2-linkage`, `-Dlzma-linkage`, `-Dlibffi-linkage`, ...) accepting `static`, `dynamic` or `off`, so you can mix and match per package. See [Per-library linkage](#per-library-linkage).

## Manifest

The CPython executable distributed on most systems is **not** a standalone piece of software.<br>
If you copy that binary to another system, even with the same operating system and CPU architecture,
it is not guaranteed to work there. <br>
The reason is that the default interpreter binary is usually dynamically linked against a bunch of system libraries,
which become hidden dependencies of your interpreter and, by extension, of your Python projects.
CPython is shipped on many Linux distributions as it's heavily used for housekeeping/scripting, and since these distributions also happen to be responsible for shipping said dynamic libraries,
that approach works pretty well for them.<br>
However, once you use Python as a *programming* language rather than a *scripting* one, the fact that the
interpreter itself is not a freestanding piece of software gets mildly annoying; once you have to distribute
binaries at large scale, maybe on a wide range of platforms, it becomes *extremely* annoying, if not a real deal-breaker.
Distributing binaries reliably is no longer trivial.

The good news is that dynamically linking these 3rd party dependencies is not a necessity by design. It is mostly a consequence of CPython being shipped by Linux distributions (which can afford to manage them directly since they are also responsible for them), and of historical practices in the C/C++ build ecosystem.

Thus, this project provides the following:

* A `build.zig`-based pipeline to build the CPython interpreter, which by itself already has two immediate benefits:
  * Building only requires the Zig compiler (0.17.x) and nothing else, which is itself downloadable as a freestanding binary.
  * You can cross-compile the interpreter, as the Zig compiler supports cross-compilation natively.
* Similar `build.zig` pipelines for most 3rd party libraries that CPython depends on (see vendors in this package). Some of them already had an existing Zig pipeline (see [allyourcodebase](https://github.com/allyourcodebase)), in which case this project uses them directly; for the others we vendor our own version. They support cross-compiling, which is one of the main requirements.
* A programmatic interface on top of all the compile-time options/flags that CPython supports.
* Python bindings on top of all of that, abstracting the Zig compiler away and providing a similar programmatic interface on the Python side.

## Building with `zig build`

```sh
zig build
```

Produces `zig-out/bin/python` (+ `zig-out/lib/pythonX.Y`) for the host
target, CPython 3.12.13 (default), with the default library linkages.

### Selecting a CPython version

```sh
zig build -Dcpython-version=3.13.8
```

Curated versions: `3.11.13`, `3.12.13` (default), `3.13.8`, `3.14.2`,
`3.15.0` (see `build.zig.zon`). Any other source (a fork, an
unreleased tag) can be added with `zig fetch --save=<name> <url-or-git-ref>`
run from this project root, then selected the same way:
`-Dcpython-version=<name>`.

To build from an already-extracted tree instead (e.g. the checked-in
`cpython/` submodule), use `-Dcpython-path=<dir>` — this bypasses
`-Dcpython-version` entirely.

### Debug builds vs. Zig's own optimization levels

`-Doptimize=...` is **Zig's** build-mode flag, but it does double duty here:
it also selects CPython's own configure-time build mode, not just how the
glue/build-system code around it is compiled.

* `-Doptimize=Debug` → configures CPython with `--with-pydebug`: a real
  **Python debug build** (`Py_DEBUG`, extra runtime assertions, reference
  count debugging, a `d` ABI suffix on extension modules). It does not
  only set Zig's own compile mode: it changes CPython's ABI and
  runtime behavior.
* `-Doptimize=ReleaseFast` / `-Doptimize=ReleaseSafe` / `-Doptimize=ReleaseSmall`
  → CPython is configured with `--enable-optimizations` and without
  `--with-pydebug`. CPython's own `OPT` variable (`-DNDEBUG -O3`, set by
  `./configure` for any non-debug build, independently of that flag) — not
  Zig's own per-mode default (`-O2`, `-O2`, `-Os` respectively) — is what
  CPython's C sources actually get compiled with: `./configure`'s flags are
  passed explicitly per file and land *after* Zig's own optimize-derived
  flags in the compile command, and the last `-O` flag on the line wins. So
  all three modes produce CPython object code built at the same
  optimization level; they only differ in Zig-internal defaults
  (safety-check codegen) that have no effect on CPython's own sources here.
  Note that `--enable-optimizations` upstream additionally means PGO, but
  that step belongs to CPython's `make` rule, which this pipeline does not
  run: **no PGO is performed**.

Independently of `-Doptimize`, `-Dstrip=true|false` controls whether debug
info/symbols are stripped from the produced artifacts at link time (default:
Zig's own per-optimize-mode default). This is unrelated to `--with-pydebug`
— it only affects whether DWARF/symbols ship in the binaries, not CPython's
build mode or ABI.

```sh
# Debug (Py_DEBUG) build of 3.13.8
zig build -Doptimize=Debug -Dcpython-version=3.13.8

# Optimized (--enable-optimizations) release build, stripped
zig build -Doptimize=ReleaseFast -Dstrip=true
```

## Per-library linkage

Every 3rd party dependency has its own `-D<lib>-linkage=` option.
Libraries are independent: you can static-link OpenSSL while keeping SQLite dynamic.

| Library | Accepted values | Default |
| --- | --- | --- |
| `openssl`, `zlib`, `libffi`, `sqlite`, `bz2`, `lzma` | `static`, `dynamic`, `off` | `static` |
| `ncurses`, `readline`, `tk` | `dynamic`, `off` **only** (no vendored build; `static` is rejected) | `dynamic` |

* `static`: vendored sources are built and linked into the interpreter (default for the libraries that have a vendored build).
* `dynamic`: CPython's stock behavior, linking against the library found on the build/target system.
* `off`: the library, and the extension modules depending on it, are left out.

Two global options are orthogonal to these:

* `-Dlibc-linkage=static|dynamic`: fully static (musl) or dynamically linked libc.
* `-Dpython-linkage=static|dynamic|off`: build `libpythonX.Y` as a library, or compile everything into one monolithic executable (`off`, default).

```sh
# static everything (default), except SQLite taken from the system, and no lzma
zig build -Dsqlite-linkage=dynamic -Dlzma-linkage=off
```

> [!NOTE]
> Choosing `dynamic` for a library trades standalone-ness for smaller binaries, shared security updates, or compatibility with system libraries. The choice is yours, per package.

## Limitations

Standalone-ness and cross-compilation are not uniform across the whole interpreter.

* **Windows**: not supported yet (`zig build` panics for Windows targets). CPython's Windows build is driven by MSBuild project files rather than `./configure`, so the POSIX pipeline does not carry over.
* **`tkinter` / `turtle` / IDLE**: no static support, and none planned. Tcl/Tk is not vendored; `-Dtk-linkage` supports only `dynamic` (system library) or `off`.
* **`curses`** (`_curses`, `_curses_panel`): ncurses is not vendored; `-Dncurses-linkage` supports only `dynamic` (system library) or `off`.
* **`readline`**: not vendored (no suitable package); `-Dreadline-linkage` supports only `dynamic` (system library) or `off`. The interpreter works without it, but the REPL then has no line editing/history.
* **`_uuid`, `_gdbm`, `_dbm`**: not built. `uuid.uuid1()`/`uuid4()` and `dbm.dumb` work as pure-Python fallbacks.
* **`nis`**: not supported (removed from CPython 3.13).
* **Fully static builds (`-Dlibc-linkage=static`)**: musl-static has no working `dlopen`. Extension modules must be built into the interpreter, third-party C-extension wheels (manylinux/glibc) cannot be loaded, and `ctypes.CDLL` of arbitrary `.so` files does not work. Use `-Dlibc-linkage=dynamic`, or `-Dpython-linkage=dynamic`, to regain `dlopen`.
* **OpenSSL**: built with assembly optimizations disabled, so cryptographic performance is lower than stock builds.
* **Cross-compilation**: 3rd party libraries are verified on `x86_64-linux-musl` and `aarch64-linux-musl` (the latter under QEMU for OpenSSL). Other targets (including macOS) are not tested. Cross-compiled interpreters cannot be run on the build host, so they are not smoke-tested at build time.
* **Relocatability**: CPython bakes absolute paths (`sys.prefix`, `sysconfig`, RPATH) at build time; relocating the output tree may require extra patching.
