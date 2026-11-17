"""
Compilation option, main interface to invoke the zig compiler
on build.zig.

@date: 31.08.2026
@author: Baptiste Pestourie
"""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Iterable
from dataclasses import dataclass, field
from enum import Enum, StrEnum
from pathlib import Path
from typing import Literal

from .pyconfig import MacroPatch


class LibCLinkage(Enum):
    """Linkage for libc: mandatory, no "off" variant."""

    STATIC = "static"
    DYNAMIC = "dynamic"


class Linkage(Enum):
    """Linkage for an optional third-party dependency, or "off" to disable it."""

    STATIC = "static"
    DYNAMIC = "dynamic"
    OFF = "off"


class OptimizeMode(Enum):
    """Mirrors Zig's std.builtin.OptimizeMode, as accepted by `-Doptimize=`."""

    DEBUG = "Debug"
    RELEASE_SAFE = "ReleaseSafe"
    RELEASE_FAST = "ReleaseFast"
    RELEASE_SMALL = "ReleaseSmall"


class BuildStep(StrEnum):
    """Top-level `zig build` steps this project defines."""

    INSTALL = "install"
    UNINSTALL = "uninstall"
    #: Runs `./configure` (and, for a musl target, the automatic pyconfig.h patch)
    #: only -- no compiling. `./configure` itself takes seconds; it's the *compile*
    #: `install` goes on to do that costs minutes. Useful when only the resulting
    #: `<cwd>/cpython/pyconfig.h` is wanted, target-correctly-detected, without
    #: paying for a full build just to get one.
    CONFIGURE = "configure"
    #: Builds only musl's own loader/libc (`lib/ld-musl-<arch>.so.1`) for a musl
    #: `-Dtarget`. `install` builds it too whenever `libc_linkage=DYNAMIC` -- an
    #: interpreter linked that way cannot run without it, since Zig links musl but
    #: does not ship a musl runtime. Requesting it alone is for consumers that already
    #: have the interpreter and only need the file to ship next to it.
    MUSL_LOADER = "musl-loader"


type Library = Literal[
    "openssl", "libffi", "ncurses", "readline", "sqlite", "zlib", "bz2", "lzma", "tk"
]

#: `build.zig`, `build.zig.zon`, `build/`, and the `cpython` submodule are
#: force-included into the wheel as siblings under this directory (see
#: pyproject.toml). build.zig resolves `cpython`'s path relative to its own
#: location, so this is the only place that needs to know it -- `zig_build`
#: below just needs to run with this as `cwd` for the two to line up.
VENDORED_PROJECT_DIR = Path(__file__).parent / "_vendor"


@dataclass(frozen=True, slots=True)
class BuildOptions:
    """Options accepted by this project's build.zig (see build/options.zig)."""

    target: str | None = None
    optimize: OptimizeMode | None = None
    libraries: dict[Library, Linkage] = field(default_factory=dict)
    libc_linkage: LibCLinkage | None = None
    python_linkage: Linkage | None = None
    pyconfig_header: Path | None = None
    #: `pyconfig.h` macro overrides, applied on top of whatever `./configure`
    #: produced *and* on top of this project's own automatic musl/cross fixups
    #: (see `byp.pyconfig`, and `build/pyconfig.zig` for the Zig side
    #: that actually rewrites the header). Later entries win, so these override
    #: the built-in fixups rather than the other way round. Lets a caller
    #: correct a single misdetected macro without hand-maintaining a whole
    #: `pyconfig_header` file; a name that isn't in the header fails the build.
    pyconfig_macros: tuple[MacroPatch, ...] = ()
    #: Drop debug info and symbols from every produced artifact at link time.
    #: `None` leaves Zig's own per-optimize-mode default. Not implied by
    #: `optimize`: CPython's `PY_CORE_CFLAGS` carry `-g` unconditionally (they
    #: come from the ./configure-generated Makefile, which knows nothing about
    #: this build's optimize mode), so even a release build emits full DWARF
    #: without this.
    strip: bool | None = None
    #: Extension module names to compile directly into the main `python`
    #: executable (a `PyInit_<name>` linked straight in and registered in a
    #: static `_PyImport_Inittab`) instead of as a `dlopen()`'d `.so`. Only
    #: meaningful with `python_linkage=Linkage.OFF` (see `build/options.zig`);
    #: a no-op otherwise.
    static_modules: tuple[str, ...] = ()
    #: Extension module names to skip entirely -- no `.so`, no builtin, as if
    #: the module did not exist. For modules whose system dependency isn't
    #: modeled by any `libraries` entry (e.g. `_blake2`'s `libb2`).
    disabled_modules: tuple[str, ...] = ()

    def to_args(self) -> list[str]:
        """Render as `zig build` CLI arguments (`-Dname=value`)."""
        args = []
        if self.target is not None:
            args.append(f"-Dtarget={self.target}")
        if self.optimize is not None:
            args.append(f"-Doptimize={self.optimize.value}")
        for library, linkage in self.libraries.items():
            args.append(f"-D{library}-linkage={linkage.value}")
        if self.libc_linkage is not None:
            args.append(f"-Dlibc-linkage={self.libc_linkage.value}")
        if self.python_linkage is not None:
            args.append(f"-Dpython-linkage={self.python_linkage.value}")
        if self.pyconfig_header is not None:
            args.append(f"-Dpyconfig-header={self.pyconfig_header}")
        args.extend(patch.to_arg() for patch in self.pyconfig_macros)
        if self.strip is not None:
            args.append(f"-Dstrip={str(self.strip).lower()}")
        if self.static_modules:
            args.append(f"-Dstatic-modules={','.join(self.static_modules)}")
        if self.disabled_modules:
            args.append(f"-Ddisabled-modules={','.join(self.disabled_modules)}")
        return args


def zig_build(
    options: BuildOptions = BuildOptions(),
    *,
    step: BuildStep = BuildStep.INSTALL,
    extra_args: Iterable[str] = (),
    cwd: Path | None = None,
    zig: Path | None = None,
) -> subprocess.CompletedProcess[bytes]:
    """Invoke `zig build` with `options`.

    `zig` is the path to the `zig` executable; if omitted, the one shipped
    by the `ziglang` PyPI package is used (`python -m ziglang`).

    `cwd` is the directory to run `zig build` from, i.e. where it looks for
    `build.zig` and, relative to that, the `cpython` source tree. If omitted,
    defaults to the vendored copy bundled in this package (`VENDORED_PROJECT_DIR`).
    """
    command = [str(zig)] if zig is not None else [sys.executable, "-m", "ziglang"]
    directory = cwd if cwd is not None else VENDORED_PROJECT_DIR
    args = [
        *command,
        "build",
        step.value,
        *options.to_args(),
        *extra_args,
    ]
    return subprocess.run(args, cwd=directory, check=True)
