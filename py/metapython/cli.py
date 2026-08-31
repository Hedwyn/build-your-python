"""
Command-line interface to metapython. Requires the optional `cli` extra
(`click`): `uv pip install metapython[cli]`.

@date: 31.08.2026
@author: Baptiste Pestourie
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import get_args

try:
    import click
except ImportError:
    print(
        "metapython.cli requires the 'cli' extra: uv pip install metapython[cli]",
        file=sys.stderr,
    )
    raise SystemExit(1) from None

from . import fetch as fetch_
from .compile import (
    BuildOptions,
    BuildStep,
    LibCLinkage,
    Library,
    Linkage,
    OptimizeMode,
    zig_build,
)

LIBRARIES = get_args(Library)

LOG_LEVELS = ("CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG")


def _parse_library(value: str) -> tuple[Library, Linkage]:
    name, _, linkage = value.partition("=")
    if not linkage:
        raise click.BadParameter(f"expected NAME=LINKAGE, got {value!r}")
    if name not in LIBRARIES:
        raise click.BadParameter(
            f"unknown library {name!r}, expected one of {LIBRARIES}"
        )
    try:
        return name, Linkage(linkage)
    except ValueError:
        choices = [linkage.value for linkage in Linkage]
        raise click.BadParameter(
            f"unknown linkage {linkage!r}, expected one of {choices}"
        ) from None


@click.group()
@click.option(
    "--log-level",
    type=click.Choice(LOG_LEVELS, case_sensitive=False),
    default="WARNING",
    show_default=True,
    help="Logging verbosity.",
)
@click.option(
    "-v",
    "--verbose",
    count=True,
    help="Increase logging verbosity (-v: INFO, -vv: DEBUG). Overrides --log-level.",
)
def cli(log_level: str, verbose: int) -> None:
    """Ship CPython source + Zig toolchain; build a static interpreter."""
    level = ["WARNING", "INFO", "DEBUG"][min(verbose, 2)] if verbose else log_level
    logging.basicConfig(level=level, format="%(levelname)s %(name)s: %(message)s")


@cli.command()
@click.option(
    "--url",
    default=fetch_.MIRROR_URL,
    show_default=True,
    help="Zig toolchain archive URL.",
)
@click.option(
    "--target",
    type=click.Path(path_type=Path, file_okay=False),
    default=None,
    help="Directory to place the downloaded archive in (default: a temp dir, removed after).",
)
def fetch(url: str, target: Path | None) -> None:
    """Download the pinned Zig toolchain."""
    with fetch_.fetch(url, target=target) as archive:
        click.echo(archive)


@cli.command()
@click.option(
    "--target", "zig_target", default=None, help="Zig target triple (-Dtarget=)."
)
@click.option(
    "--optimize",
    type=click.Choice([mode.value for mode in OptimizeMode]),
    default=None,
    help="Zig optimize mode (-Doptimize=).",
)
@click.option(
    "--lib",
    "libraries",
    multiple=True,
    metavar="NAME=LINKAGE",
    help=f"Per-library linkage, repeatable. NAME in {LIBRARIES}, LINKAGE in static/dynamic/off.",
)
@click.option(
    "--libc-linkage",
    type=click.Choice([linkage.value for linkage in LibCLinkage]),
    default=None,
)
@click.option(
    "--python-linkage",
    type=click.Choice([linkage.value for linkage in Linkage]),
    default=None,
)
@click.option(
    "--pyconfig-header",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Bring-your-own pyconfig.h.",
)
@click.option(
    "--step",
    type=click.Choice([step.value for step in BuildStep]),
    default=BuildStep.INSTALL.value,
    show_default=True,
)
@click.option(
    "--cwd",
    type=click.Path(exists=True, file_okay=False, path_type=Path),
    default=None,
    help="Directory to run `zig build` from (default: this package's vendored copy).",
)
@click.option(
    "--zig",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Path to the `zig` executable (default: fetch the pinned toolchain).",
)
@click.argument("extra_args", nargs=-1, type=click.UNPROCESSED)
def build(
    zig_target: str | None,
    optimize: str | None,
    libraries: tuple[str, ...],
    libc_linkage: str | None,
    python_linkage: str | None,
    pyconfig_header: Path | None,
    step: str,
    cwd: Path | None,
    zig: Path | None,
    extra_args: tuple[str, ...],
) -> None:
    """Invoke `zig build` with the given options."""
    options = BuildOptions(
        target=zig_target,
        optimize=OptimizeMode(optimize) if optimize is not None else None,
        libraries=dict(_parse_library(value) for value in libraries),
        libc_linkage=LibCLinkage(libc_linkage) if libc_linkage is not None else None,
        python_linkage=Linkage(python_linkage) if python_linkage is not None else None,
        pyconfig_header=pyconfig_header,
    )
    zig_build(
        options,
        step=BuildStep(step),
        extra_args=extra_args,
        cwd=cwd,
        zig=zig,
    )


def main() -> None:
    cli()


if __name__ == "__main__":
    main()
