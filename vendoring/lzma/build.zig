//! No `allyourcodebase/lzma` package exists (checked: see
//! vendored_libraries_plan.md), so this is a from-scratch build.zig, unlike
//! sqlite3/bzip2. Two things make it different from a typical
//! "list the sources, generate a small config header" package:
//!
//! 1. **Source, not release tarball.** liblzma is the library the 2024 xz
//!    backdoor (CVE-2024-3094) was planted in -- specifically in the
//!    *release tarballs* of versions 5.6.0/5.6.1, via a doctored
//!    `build-to-host.m4`/test file that was never present in the plain git
//!    history. `build.zig.zon`'s `.xz` dependency points at a GitHub
//!    commit-archive URL (content identical to a `git checkout` at that
//!    commit, unlike xz.org's own release tarballs), pinned to a 5.8.4 tag
//!    commit -- nowhere near the compromised pair.
//! 2. **No config.h at all.** Modern xz (5.8.x) dropped autotools' config.h
//!    convention for its own CMake build in favor of passing every `HAVE_*`/
//!    feature macro directly as a compiler `-D` flag (see this upstream
//!    tree's own `CMakeLists.txt`) -- so this build.zig does the same
//!    instead of hand-writing a config.h, mirroring upstream's own current
//!    approach rather than the older, now-stale `dos/config.h` still checked
//!    into the tree. The macro list below was cross-checked line-by-line
//!    against that `CMakeLists.txt` for this exact pinned version.
//!
//! Threading is deliberately left out (no `stream_encoder_mt.c`/
//! `stream_decoder_mt.c`/`outqueue.c`/`hardware_cputhreads.c`, no
//! `MYTHREAD_POSIX`): CPython's `_lzma` module never asks for the threaded
//! encoder, and skipping it avoids pulling `mythread.h`'s pthread path in at
//! all -- `_lzma`'s own `lzma_stream_encoder_mt` bindings are the only CPython
//! entry point that would need it, gated behind `LZMA_STREAM_ENCODER_MT` in
//! `lzma/container.h`, which was never called from `_lzmamodule.c`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xz = b.dependency("xz", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Every filter/check/match-finder liblzma supports, matching a default
    // `cmake .` build of this tree -- CPython's `_lzma.c` reaches for the
    // easy/stream/alone/auto/raw encoders and decoders, all of which dispatch
    // through these HAVE_* tables at runtime by filter ID, so nothing here is
    // pruneable without also pruning which filters `lzma.FILTER_*` can name.
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-DPACKAGE_NAME=\"XZ Utils\"",
        "-DPACKAGE_BUGREPORT=\"xz@tukaani.org\"",
        "-DPACKAGE_URL=\"https://tukaani.org/xz/\"",

        "-DHAVE_STDBOOL_H",
        "-DHAVE__BOOL",
        "-DHAVE_STDINT_H",
        "-DHAVE_INTTYPES_H",

        // System-extension macros glibc/musl (and everything else this
        // project doesn't target) gate their extra POSIX/GNU declarations
        // behind -- harmless no-ops on whichever of these don't apply.
        "-D_GNU_SOURCE",
        "-D_NETBSD_SOURCE",
        "-D_OPENBSD_SOURCE",
        "-D__EXTENSIONS__",
        "-D_POSIX_PTHREAD_SEMANTICS",
        "-D_DARWIN_C_SOURCE",
        "-D_TANDEM_SOURCE",
        "-D_ALL_SOURCE",
        // 32-bit off_t is too small for real archives; harmless where off_t
        // is already 64-bit (e.g. every 64-bit target).
        "-D_FILE_OFFSET_BITS=64",

        // This project only ever targets Linux -- sysconf(_SC_PHYS_PAGES) is
        // always the right answer here, unlike upstream's own AIX/HP-UX/BSD
        // sysctl()/pstat() fallbacks.
        "-DTUKLIB_PHYSMEM_SYSCONF",

        // zig cc is Clang: both builtins always exist, no fallback needed.
        "-DHAVE___BUILTIN_BSWAPXX",
        "-DHAVE___BUILTIN_ASSUME_ALIGNED",

        // Checks: all three, matching a default build.
        "-DHAVE_CHECK_CRC32",
        "-DHAVE_CHECK_CRC64",
        "-DHAVE_CHECK_SHA256",

        // Match finders: all five, matching a default build.
        "-DHAVE_MF_HC3",
        "-DHAVE_MF_HC4",
        "-DHAVE_MF_BT2",
        "-DHAVE_MF_BT3",
        "-DHAVE_MF_BT4",

        // Encoders and decoders: LZMA1/LZMA2/delta plus every BCJ filter --
        // these are portable data transforms, not host-arch-specific code
        // (encoding an ARM BCJ stream works the same on an x86_64 build of
        // this library), so there's no reason to prune by target.
        "-DHAVE_ENCODERS",
        "-DHAVE_ENCODER_LZMA1",
        "-DHAVE_ENCODER_LZMA2",
        "-DHAVE_ENCODER_DELTA",
        "-DHAVE_ENCODER_X86",
        "-DHAVE_ENCODER_ARM",
        "-DHAVE_ENCODER_ARMTHUMB",
        "-DHAVE_ENCODER_ARM64",
        "-DHAVE_ENCODER_POWERPC",
        "-DHAVE_ENCODER_IA64",
        "-DHAVE_ENCODER_SPARC",
        "-DHAVE_ENCODER_RISCV",
        "-DHAVE_DECODERS",
        "-DHAVE_DECODER_LZMA1",
        "-DHAVE_DECODER_LZMA2",
        "-DHAVE_DECODER_DELTA",
        "-DHAVE_DECODER_X86",
        "-DHAVE_DECODER_ARM",
        "-DHAVE_DECODER_ARMTHUMB",
        "-DHAVE_DECODER_ARM64",
        "-DHAVE_DECODER_POWERPC",
        "-DHAVE_DECODER_IA64",
        "-DHAVE_DECODER_SPARC",
        "-DHAVE_DECODER_RISCV",
        // .lz (lzip) read support -- on by default upstream, needs the LZMA1
        // decoder (enabled above).
        "-DHAVE_LZIP_DECODER",
    }) catch @panic("OOM");

    // Target-dependent, unlike everything above.
    if (target.result.cpu.arch.endian() == .big) {
        flags.append(b.allocator, "-DWORDS_BIGENDIAN") catch @panic("OOM");
    }
    // Matches tuklib_integer.cmake's own fast-unaligned-access guess for
    // these families; conservatively left off (slower, never wrong) for
    // everything else instead of guessing.
    switch (target.result.cpu.arch) {
        .x86, .x86_64, .aarch64, .aarch64_be => flags.append(
            b.allocator,
            "-DTUKLIB_FAST_UNALIGNED_ACCESS",
        ) catch @panic("OOM"),
        else => {},
    }

    mod.addCSourceFiles(.{
        .root = xz.path(""),
        .files = &.{
            "src/liblzma/check/check.c",
            "src/liblzma/check/crc32_fast.c",
            "src/liblzma/check/crc64_fast.c",
            "src/liblzma/check/sha256.c",
            "src/liblzma/common/alone_decoder.c",
            "src/liblzma/common/alone_encoder.c",
            "src/liblzma/common/auto_decoder.c",
            "src/liblzma/common/block_buffer_decoder.c",
            "src/liblzma/common/block_buffer_encoder.c",
            "src/liblzma/common/block_decoder.c",
            "src/liblzma/common/block_encoder.c",
            "src/liblzma/common/block_header_decoder.c",
            "src/liblzma/common/block_header_encoder.c",
            "src/liblzma/common/block_util.c",
            "src/liblzma/common/common.c",
            "src/liblzma/common/easy_buffer_encoder.c",
            "src/liblzma/common/easy_decoder_memusage.c",
            "src/liblzma/common/easy_encoder.c",
            "src/liblzma/common/easy_encoder_memusage.c",
            "src/liblzma/common/easy_preset.c",
            "src/liblzma/common/file_info.c",
            "src/liblzma/common/filter_buffer_decoder.c",
            "src/liblzma/common/filter_buffer_encoder.c",
            "src/liblzma/common/filter_common.c",
            "src/liblzma/common/filter_decoder.c",
            "src/liblzma/common/filter_encoder.c",
            "src/liblzma/common/filter_flags_decoder.c",
            "src/liblzma/common/filter_flags_encoder.c",
            "src/liblzma/common/hardware_physmem.c",
            "src/liblzma/common/index.c",
            "src/liblzma/common/index_decoder.c",
            "src/liblzma/common/index_encoder.c",
            "src/liblzma/common/index_hash.c",
            "src/liblzma/common/lzip_decoder.c",
            "src/liblzma/common/microlzma_decoder.c",
            "src/liblzma/common/microlzma_encoder.c",
            "src/liblzma/common/stream_buffer_decoder.c",
            "src/liblzma/common/stream_buffer_encoder.c",
            "src/liblzma/common/stream_decoder.c",
            "src/liblzma/common/stream_encoder.c",
            "src/liblzma/common/stream_flags_common.c",
            "src/liblzma/common/stream_flags_decoder.c",
            "src/liblzma/common/stream_flags_encoder.c",
            "src/liblzma/common/string_conversion.c",
            "src/liblzma/common/vli_decoder.c",
            "src/liblzma/common/vli_encoder.c",
            "src/liblzma/common/vli_size.c",
            "src/liblzma/delta/delta_common.c",
            "src/liblzma/delta/delta_decoder.c",
            "src/liblzma/delta/delta_encoder.c",
            "src/liblzma/lz/lz_decoder.c",
            "src/liblzma/lz/lz_encoder.c",
            "src/liblzma/lz/lz_encoder_mf.c",
            "src/liblzma/lzma/fastpos_table.c",
            "src/liblzma/lzma/lzma2_decoder.c",
            "src/liblzma/lzma/lzma2_encoder.c",
            "src/liblzma/lzma/lzma_decoder.c",
            "src/liblzma/lzma/lzma_encoder.c",
            "src/liblzma/lzma/lzma_encoder_optimum_fast.c",
            "src/liblzma/lzma/lzma_encoder_optimum_normal.c",
            "src/liblzma/lzma/lzma_encoder_presets.c",
            "src/liblzma/rangecoder/price_table.c",
            "src/liblzma/simple/simple_coder.c",
            "src/liblzma/simple/simple_decoder.c",
            "src/liblzma/simple/simple_encoder.c",
            "src/liblzma/simple/x86.c",
            "src/liblzma/simple/arm.c",
            "src/liblzma/simple/armthumb.c",
            "src/liblzma/simple/arm64.c",
            "src/liblzma/simple/powerpc.c",
            "src/liblzma/simple/ia64.c",
            "src/liblzma/simple/sparc.c",
            "src/liblzma/simple/riscv.c",
            "src/common/tuklib_physmem.c",
        },
        .flags = flags.items,
    });

    for ([_][]const u8{
        "src/liblzma/api",
        "src/liblzma/common",
        "src/liblzma/check",
        "src/liblzma/lz",
        "src/liblzma/rangecoder",
        "src/liblzma/lzma",
        "src/liblzma/delta",
        "src/liblzma/simple",
        "src/common",
    }) |dir| mod.addIncludePath(xz.path(dir));

    const lib = b.addLibrary(.{
        .name = "lzma",
        .root_module = mod,
    });
    lib.installHeader(xz.path("src/liblzma/api/lzma.h"), "lzma.h");
    lib.installHeadersDirectory(xz.path("src/liblzma/api/lzma"), "lzma", .{});
    b.installArtifact(lib);
}
