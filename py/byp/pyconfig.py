"""
Typed model of `pyconfig.h`'s macro syntax, and of the overrides this project
applies to it. A 1:1 port of `build/pyconfig.zig` -- same three macro states,
same last-wins patch semantics, same fixup lists -- so that a Python caller
can reason about (and produce) the exact header `zig build` would, without
shelling out to it.

Two ways to use it, matching the two Zig-side entry points:

* Hand the patches to `zig build` and let it do the rewriting:
  `BuildOptions(pyconfig_macros=(...))` renders them as
  `-Dpyconfig-define=`/`-Dpyconfig-undef=` (see `byp.compile`).
* Or rewrite a `pyconfig.h` here and pass the result as
  `BuildOptions(pyconfig_header=...)`: `apply_patches` is the primitive for
  that, and `cross_patches` gives the same list build.zig would have applied
  on its own.

Note what this is *not*: a struct holding all ~350 of `pyconfig.h`'s macros
plus a from-scratch generator for the file. `pyconfig.h` interleaves its
macros with per-macro doc comments, guards, function-like macros and
`#if defined(...)` blocks; reproducing all of that from a struct would have
to either drop it or re-emit it verbatim, for no benefit over naming the
handful of macros that actually need to change. Patching leaves the rest
byte-identical, which keeps the result diffable against a fresh
`./configure` run.

@date: 10.09.2026
@author: Baptiste Pestourie
"""

from __future__ import annotations

import platform
import re
from collections.abc import Iterable
from dataclasses import dataclass
from typing import final

_DEFINE_PREFIX = "#define "
_UNDEF_PREFIX = "/* #undef "
_UNDEF_SUFFIX = " */"
_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


@final
@dataclass(frozen=True, slots=True)
class Undef:
    """`/* #undef NAME */` -- the macro is not defined."""

    def render(self, name: str) -> str:
        return f"{_UNDEF_PREFIX}{name}{_UNDEF_SUFFIX}"

    def to_arg(self, name: str) -> str:
        return f"-Dpyconfig-undef={name}"


@final
@dataclass(frozen=True, slots=True)
class Flag:
    """`#define NAME` -- defined with no value (rare; feature-test markers)."""

    def render(self, name: str) -> str:
        return f"{_DEFINE_PREFIX}{name}"

    def to_arg(self, name: str) -> str:
        return f"-Dpyconfig-define={name}"


@final
@dataclass(frozen=True, slots=True)
class Value:
    """`#define NAME <text>`, written verbatim.

    The caller already knows whether `text` is an integer, a quoted string or
    a bare token; `pyconfig.h` mixes all three depending on the macro, so no
    quoting or conversion happens here.
    """

    text: str

    def render(self, name: str) -> str:
        return f"{_DEFINE_PREFIX}{name} {self.text}"

    def to_arg(self, name: str) -> str:
        return f"-Dpyconfig-define={name}={self.text}"


type MacroState = Undef | Flag | Value

#: Singletons for the two stateless variants -- `Undef()`/`Flag()` are equal
#: to these anyway (frozen dataclasses with no fields), these just read better
#: in a patch list.
UNDEF: MacroState = Undef()
FLAG: MacroState = Flag()


@final
@dataclass(frozen=True, slots=True)
class MacroPatch:
    """What one named macro should become."""

    name: str
    state: MacroState

    def render(self) -> str:
        """The single `pyconfig.h` line this patch produces."""
        return self.state.render(self.name)

    def to_arg(self) -> str:
        """The `zig build` option that asks build.zig to apply this patch."""
        return self.state.to_arg(self.name)


class MacroNotFoundError(LookupError):
    """A patch named a macro that isn't in the `pyconfig.h` being patched.

    Almost always a typo, or a macro CPython's own `configure.ac` renamed or
    removed since the patch list was written. Raised rather than silently
    no-op'd: the whole point of naming macros explicitly is to know they took
    effect.
    """

    def __init__(self, names: Iterable[str]) -> None:
        self.names: tuple[str, ...] = tuple(names)
        super().__init__(
            "pyconfig patch targets not found in the given pyconfig.h "
            f"(renamed/removed upstream?): {', '.join(self.names)}"
        )


def match_macro_name(line: str) -> str | None:
    """The macro `line` defines or undefines, or `None` if it does neither.

    Recognizes both spellings `pyconfig.h` uses for a simple macro named
    `NAME`: `#define NAME` / `#define NAME <value>`, and `/* #undef NAME */`.
    Function-like macros (`#define FOO(x) ...`) deliberately return `None`:
    never a patch target, and rewriting one would corrupt it.
    """
    if line.startswith(_DEFINE_PREFIX):
        rest = line[len(_DEFINE_PREFIX) :]
        match = _IDENTIFIER.match(rest)
        if match is None:
            return None
        if rest[match.end() : match.end() + 1] == "(":
            return None
        return match.group()
    if line.startswith(_UNDEF_PREFIX) and line.endswith(_UNDEF_SUFFIX):
        return line[len(_UNDEF_PREFIX) : -len(_UNDEF_SUFFIX)]
    return None


def apply_patches(text: str, patches: Iterable[MacroPatch]) -> str:
    """Rewrite the lines of `text` naming a patched macro; leave the rest alone.

    Every other line -- doc comments, guards, macros not named in `patches` --
    comes out byte-identical. `patches` may name the same macro more than
    once; the last entry wins, which is what lets a caller append its own
    overrides after one of the built-in lists below.

    Raises `MacroNotFoundError` if any patch's macro appears nowhere in `text`.
    """
    ordered = tuple(patches)
    found = [False] * len(ordered)
    lines: list[str] = []
    for line in text.split("\n"):
        name = match_macro_name(line)
        winner: MacroPatch | None = None
        if name is not None:
            for index, patch in enumerate(ordered):
                if patch.name == name:
                    found[index] = True
                    winner = patch
        lines.append(line if winner is None else winner.render())
    missing = [
        patch.name for patch, hit in zip(ordered, found, strict=True) if not hit
    ]
    if missing:
        raise MacroNotFoundError(missing)
    return "\n".join(lines)


def parse_define(spec: str) -> MacroPatch:
    """Parse one `-Dpyconfig-define=` value.

    `NAME=VALUE` -> `Value`, bare `NAME` -> `Flag` (`#define NAME`, no value).
    Same shape as `cc`'s own `-D`, deliberately.
    """
    name, separator, value = spec.partition("=")
    _validate_name(name, spec)
    return MacroPatch(name, Value(value) if separator else FLAG)


def parse_undef(spec: str) -> MacroPatch:
    """Parse one `-Dpyconfig-undef=` value: a bare macro name.

    A separate spelling from `parse_define`, rather than a `NAME=` form, so
    that "undefine it" can never be confused with "define it to the empty
    string".
    """
    _validate_name(spec, spec)
    return MacroPatch(spec, UNDEF)


def _validate_name(name: str, spec: str) -> None:
    match = _IDENTIFIER.match(name)
    if match is None or match.end() != len(name):
        raise ValueError(f"invalid pyconfig macro {spec!r}: expected a C identifier")


#: Macros a native (non-cross-aware) `./configure` misdetects when `CC` is a
#: musl-targeted `zig cc`: each is real on glibc but absent or broken on musl,
#: and a same-CPU musl target never goes through `--host` cross mode (autoconf's
#: own test binaries run fine on the build machine), so every libc feature check
#: answers for the *host's* glibc. build.zig applies this automatically for a
#: musl `-Dtarget`; it is exported here for callers producing their own header.
MUSL_FIXUPS: tuple[MacroPatch, ...] = (
    MacroPatch("HAVE_CLOSE_RANGE", UNDEF),
    MacroPatch("HAVE_SEM_CLOCKWAIT", UNDEF),
    MacroPatch("HAVE_SYS_PIDFD_H", UNDEF),
    # musl's <sched.h> lacks the glibc-only dynamic CPU_SET_S/CPU_ALLOC_SIZE family.
    MacroPatch("HAVE_SCHED_SETAFFINITY", UNDEF),
    # musl never has this legacy SysV STREAMS header.
    MacroPatch("HAVE_STROPTS_H", UNDEF),
    # AC_CHECK_DECLS spelling (0/1, not #define/#undef) for a glibc-only dlopen() flag.
    MacroPatch("HAVE_DECL_RTLD_DEEPBIND", Value("0")),
)

#: Macros CPython's `configure.ac` gets wrong under *real* `--host`
#: cross-compilation (a different CPU architecture than the build machine's).
#: Each is decided by an `AC_RUN_IFELSE`, which cannot execute a target-arch
#: test binary on the build machine and so falls back to a hardcoded guess.
#: Established by diffing `./configure`-produced `pyconfig.h`s across
#: `x86_64` (native control), `aarch64`, `arm`, `s390x` and `i386` -- see
#: `build/pyconfig.zig`'s `cross_fixups` for the full write-up, including why
#: there is no per-CPU macro table (every genuinely CPU-tied macro -- the
#: `SIZEOF_*`/`ALIGNOF_*`/`DOUBLE_IS_*` family -- already comes out correct,
#: because autoconf measures those with compile-time probes).
CROSS_FIXUPS: tuple[MacroPatch, ...] = (
    # Cross fallback "no", but the check is about the *compiler*: `zig cc` is
    # Clang, which has GCC's computed-goto extension on every target here.
    # Off means losing CPython's threaded-code interpreter dispatch entirely.
    MacroPatch("HAVE_COMPUTED_GOTOS", Value("1")),
    # Cross fallback "no". True on both glibc and musl.
    MacroPatch("HAVE_WORKING_TZSET", Value("1")),
    # Cross fallback "no". Linux/NPTL supports only PTHREAD_SCOPE_SYSTEM.
    MacroPatch("PTHREAD_SYSTEM_SCHED_SUPPORTED", Value("1")),
    # Inverted sense, so the cross fallback lands on "broken". Both Linux
    # libcs implement sem_getvalue().
    MacroPatch("HAVE_BROKEN_SEM_GETVALUE", UNDEF),
)

#: Zig CPU-architecture names whose psABI makes `wchar_t` an *unsigned* type.
#: Checked per target with a `_Static_assert(((wchar_t) -1) < 0)` compiled by
#: `zig cc`: the ARM family (both widths, both endiannesses) is unsigned;
#: x86, x86_64, s390x, powerpc64le, riscv64, mips and loongarch64 are signed.
_UNSIGNED_WCHAR_T_ARCHES = frozenset(
    {"aarch64", "aarch64_be", "arm", "armeb", "thumb", "thumbeb"}
)


@final
@dataclass(frozen=True, slots=True)
class ArchProfile:
    """The CPU/ABI-determined part of `pyconfig.h` a cross `./configure` misses.

    Deliberately tiny, and that is the finding rather than an omission: see
    `CROSS_FIXUPS` for the four-target `pyconfig.h` diff showing that every
    other CPU-tied macro is already correct under `--host`. Kept as a struct
    anyway so that the next such macro is a field, not a new mechanism.
    """

    #: Whether the target's `wchar_t` is signed. `configure.ac`'s
    #: `ac_cv_wchar_t_signed` is an `AC_RUN_IFELSE` whose cross fallback is
    #: the conservative "yes", so a cross build for an unsigned-`wchar_t`
    #: target silently loses CPython's `HAVE_USABLE_WCHAR_T` fast path (which
    #: reads `wchar_t` directly as a code point, and is only safe when the
    #: type cannot be negative).
    wchar_t_signed: bool
    #: Size of the target's `wchar_t`, in bytes: 2 on Windows (UTF-16), 4
    #: everywhere else this project builds for.
    wchar_t_size: int

    @classmethod
    def of(cls, target: str) -> ArchProfile:
        """Derive the profile from a Zig target triple (`-Dtarget=`'s value)."""
        arch, _, rest = target.partition("-")
        return cls(
            wchar_t_signed=arch not in _UNSIGNED_WCHAR_T_ARCHES,
            wchar_t_size=2 if rest.startswith("windows") else 4,
        )

    def to_patches(self) -> tuple[MacroPatch, ...]:
        """This profile as `apply_patches` input."""
        usable = self.wchar_t_size >= 2 and not self.wchar_t_signed
        return (MacroPatch("HAVE_USABLE_WCHAR_T", Value("1") if usable else UNDEF),)


def cross_patches(target: str) -> tuple[MacroPatch, ...]:
    """Every fixup build.zig would apply on its own for `target`.

    `target` is a Zig target triple. Composed in the same order build.zig
    composes them, and with the same conditions: the musl list only for a
    musl ABI, the cross list and the arch profile only for a CPU architecture
    other than this machine's. Callers appending their own overrides should
    append them *after* these -- `apply_patches` is last-wins.
    """
    patches: list[MacroPatch] = []
    arch, _, _ = target.partition("-")
    if "musl" in target:
        patches.extend(MUSL_FIXUPS)
    if arch not in ("native", _zig_arch(platform.machine())):
        patches.extend(CROSS_FIXUPS)
        patches.extend(ArchProfile.of(target).to_patches())
    return tuple(patches)


#: `uname -m` spellings that differ from Zig's own architecture names. Only
#: the ones this project can plausibly run *on* need an entry.
_UNAME_TO_ZIG_ARCH = {
    "amd64": "x86_64",
    "arm64": "aarch64",
    "i386": "x86",
    "i686": "x86",
}


def _zig_arch(machine: str) -> str:
    return _UNAME_TO_ZIG_ARCH.get(machine, machine)
