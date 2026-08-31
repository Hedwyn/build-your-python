"""
Compilation option, main interface to invoke the zig compiler
on build.zig.

@date: 31.08.2026
@author: Baptiste Pestourie
"""

from __future__ import annotations

import subprocess
from collections.abc import Iterable
from dataclasses import dataclass, field
from enum import Enum, StrEnum
from pathlib import Path
from typing import Literal

from . import fetch


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


type Library = Literal[
    "openssl", "libffi", "ncurses", "readline", "sqlite", "zlib", "bz2", "lzma", "tk"
]


@dataclass(frozen=True, slots=True)
class BuildOptions:
    """Options accepted by this project's build.zig (see build/options.zig)."""

    target: str | None = None
    optimize: OptimizeMode | None = None
    libraries: dict[Library, Linkage] = field(default_factory=dict)
    libc_linkage: LibCLinkage | None = None
    python_linkage: Linkage | None = None
    pyconfig_header: Path | None = None

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

    `zig` is the path to the `zig` executable; if omitted, the pinned
    toolchain is fetched (see `metapython.fetch`) and used.
    """
    executable = zig if zig is not None else fetch.zig_toolchain()
    args = [
        str(executable),
        "build",
        step.value,
        *options.to_args(),
        *extra_args,
    ]
    return subprocess.run(args, cwd=cwd, check=True)
