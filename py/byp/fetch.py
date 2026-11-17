"""
byp.fetch: download the pinned Zig toolchain (build.zig.zon's
minimum_zig_version, a 0.17 dev release not yet published to the `ziglang`
PyPI package) and stage it on disk.

@date: 31.08.2026
@author: Baptiste Pestourie
"""

from __future__ import annotations

import contextlib
import logging
import shutil
import tarfile
import tempfile
import urllib.request
from collections.abc import Iterator
from pathlib import Path

# Temp: poiting to dev release of Zig 0.17 until it's released
MIRROR_URL = (
    "https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1941+71115f0ab.tar.xz"
)

DEFAULT_CACHE_DIR = Path.home() / ".cache" / "byp" / "zig"

_logger = logging.getLogger(__name__)


def download(url: str, dest: Path) -> Path:
    """Download `url` to the file `dest` and return it."""
    _logger.info("downloading %s -> %s", url, dest)
    with urllib.request.urlopen(url) as response, dest.open("wb") as out:
        shutil.copyfileobj(response, out)
    size = dest.stat().st_size
    _logger.info("downloaded %s (%d bytes)", url, size)
    return dest


@contextlib.contextmanager
def fetch(url: str = MIRROR_URL, *, target: Path | None = None) -> Iterator[Path]:
    """Download `url`, then move it into `target`.

    If `target` is given, it is used (and created if missing) and preserved
    after the context exits. Otherwise a temporary directory is used and
    removed on exit.
    """
    context = (
        contextlib.nullcontext(target)
        if target is not None
        else tempfile.TemporaryDirectory()
    )
    with context as directory:
        directory_path = Path(directory)
        directory_path.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            downloaded = download(url, Path(tmp.name))
        dest = directory_path / Path(url).name
        shutil.move(downloaded, dest)
        _logger.info("staged archive at %s", dest)
        yield dest


def archive_stem(url: str) -> str:
    """Return the toolchain directory name embedded in `url`'s filename."""
    return Path(url).name.removesuffix(".tar.xz")


def extract(archive: Path, dest: Path) -> Path:
    """Extract the `tar.xz` Zig toolchain `archive` into `dest`.

    Returns the path to the `zig` executable inside the extracted toolchain.
    """
    dest.mkdir(parents=True, exist_ok=True)
    _logger.info("extracting %s -> %s", archive, dest)
    with tarfile.open(archive) as tar:
        tar.extractall(dest, filter="data")
    return dest / archive_stem(archive.name) / "zig"


def zig_toolchain(
    url: str = MIRROR_URL, *, cache_dir: Path = DEFAULT_CACHE_DIR
) -> Path:
    """Return the path to the pinned `zig` executable, fetching it if needed.

    Downloads and extracts `url` into `cache_dir` on first use; later calls
    with the same `cache_dir` reuse the already-extracted toolchain.
    """
    executable = cache_dir / archive_stem(url) / "zig"
    if executable.exists():
        _logger.info("using cached toolchain at %s", executable)
        return executable
    _logger.info("no cached toolchain at %s, fetching %s", executable, url)
    with fetch(url) as archive:
        return extract(archive, cache_dir)
