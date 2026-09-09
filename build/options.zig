//! Build-time options for how CPython's third-party dependencies get linked,
//! passed on the `zig build` command line (e.g. `-Dopenssl-linkage=dynamic`).

const std = @import("std");

/// static/dynamic linkage of a dependency; same enum std.Build.Step.Compile
/// uses for its own `.linkage` field (see build/utils.zig's addSharedModule).
pub const Linkage = std.builtin.LinkMode;

pub const BuildOptions = struct {
    openssl_linkage: ?Linkage,
    libffi_linkage: ?Linkage,
    ncurses_linkage: ?Linkage,
    readline_linkage: ?Linkage,
    sqlite_linkage: ?Linkage,
    zlib_linkage: ?Linkage,
    bz2_linkage: ?Linkage,
    lzma_linkage: ?Linkage,
    tk_linkage: ?Linkage,
    /// Unlike the third-party deps above, libc is mandatory -- no "off".
    /// Defaults to `dynamic`. `static` builds fine but, unless paired with
    /// `python_linkage = .dynamic`, produces a mostly non-functional
    /// interpreter: a fully static (or static-PIE) executable has no usable
    /// dynamic symbol table, so every dlopen()'d extension module fails to
    /// resolve Python C-API calls (e.g. `PyExc_OSError`) against it --
    /// confirmed empirically (`readelf -d`/`--dyn-syms`, and static-PIE +
    /// explicit `dlopen(NULL, RTLD_GLOBAL)` self-registration still fail
    /// with "undefined symbol"). This is the exact libdl constraint
    /// research.md already flags. See `python_linkage` below for the fix,
    /// and the warning/panic in `parseOptions` for which combinations are
    /// actually allowed.
    ///
    /// For a musl target, `dynamic` additionally builds musl's own loader/libc into
    /// the prefix (`lib/ld-musl-<arch>.so.1`, see build/musl.zig): Zig links musl
    /// dynamically but ships no musl runtime, so the interpreter is only runnable
    /// through that file.
    libc_linkage: Linkage,
    /// Whether the core interpreter is built as a standalone library that
    /// the `python` executable and every extension module link against
    /// ("static" -> libpythonX.Y.a, "dynamic" -> libpythonX.Y.so), or
    /// compiled directly into one monolithic `python` executable ("off",
    /// null here, the default -- what this project has always done). See
    /// build.zig for both paths. "dynamic" is the one that actually fixes
    /// dlopen()'d extensions under `libc_linkage=static`: linking against a
    /// real `.so` is ordinary build-time symbol resolution, unlike relying
    /// on `-rdynamic` to export the (possibly static, unregistered) main
    /// executable's own symbols.
    python_linkage: ?Linkage,
    /// Whether to drop debug info (and the symbol table) from every artifact
    /// this build produces, at link time. `null` leaves Zig's own per-optimize
    /// -mode default in place.
    ///
    /// Worth an explicit knob rather than riding on `optimize`: CPython's own
    /// `PY_CORE_CFLAGS` carry `-g` unconditionally (they come out of the
    /// `./configure`-generated Makefile, which has no notion of this build's
    /// optimize mode), so a `ReleaseFast` build still emits full DWARF for
    /// every one of the ~1500 core translation units and every extension
    /// module. Measured on a native x86_64 build: `libpython3.12.so` 24.5 MB
    /// -> 7.3 MB, and the 62 `lib-dynload` modules 14 MB -> 4 MB, purely from
    /// stripping. Consumers that bundle this interpreter into a distributable
    /// (see smelt) pay that on every copy.
    strip: ?bool,
    /// Path to an existing `pyconfig.h` to drop into the CPython source tree
    /// instead of the one `./configure` generates. `./configure` still runs
    /// (its own `pyconfig.h` output is just overwritten afterward) since its
    /// other output, `Makefile`, is still needed. Useful when cross-compiling:
    /// autoconf's `HAVE_*`/`ac_cv_*` detection can't execute target-arch test
    /// programs and falls back to conservative (often wrong) guesses.
    pyconfig_header: ?[]const u8,
    /// Extension module names to compile directly into the main `python`
    /// executable (CPython's own "builtin module" mechanism: a `PyInit_<name>`
    /// C function linked straight in and registered in a static
    /// `_PyImport_Inittab`, called directly -- no separate `.so`, no
    /// `dlopen()`, no dynamic linking of any kind) instead of building them
    /// as ordinary shared modules.
    ///
    /// Exists specifically for `libc-linkage=static` targets where `dlopen()`
    /// itself doesn't work: `-Dtarget=x86_64-linux-musl` was verified
    /// empirically (both plain-static and static-PIE) to compile clean,
    /// correctly populate `_PyImport_DynLoadFiletab`, and then fail *every*
    /// `dlopen()` call at runtime with musl's own `dlerror()` text ("Dynamic
    /// loading not supported" -- confirmed absent from CPython's own source
    /// entirely, so it's musl's libc refusing, not a CPython-side check).
    /// Bypassing `dlopen()` entirely for the modules named here is the only
    /// way found so far to get a `libc-linkage=static` build with working
    /// extension modules at all. Only meaningful with `python-linkage=off`
    /// (see build.zig): that's the only shape where the modules end up in the
    /// same compilation unit as the symbols their `PyInit_*` functions need.
    static_modules: []const []const u8,
    /// Extension module names to skip entirely (no shared `.so`, no builtin
    /// -- as if the module didn't exist). Unlike the lib-linkage `off`
    /// values, this isn't tied to any of the third-party deps this project
    /// otherwise models: some modules pull in a system lib that's neither
    /// vendored nor represented as a linkage knob at all (e.g. `_blake2`'s
    /// `libb2`, `nis`'s `libnsl`/`libtirpc` -- both real on glibc, both
    /// missing for `-Dtarget=*-linux-musl`; see roadmap.md's "not yet
    /// triaged" musl module-compile-failure list). Escape hatch for
    /// exactly that: unblock a target/config where the default module set
    /// doesn't build, without adding a bespoke linkage option per module.
    disabled_modules: []const []const u8,
};

const lib_names = [_][]const u8{
    "openssl", "libffi", "ncurses", "readline", "sqlite", "zlib", "bz2", "lzma", "tk",
};

/// "static" / "dynamic" / "off" -> `?Linkage` ("off" -> null, i.e. don't link
/// this dependency at all). Panics on anything else -- a build option typo is
/// a developer error, not something to recover from at runtime.
fn parseLinkage(raw: []const u8) ?Linkage {
    if (std.mem.eql(u8, raw, "static")) return .static;
    if (std.mem.eql(u8, raw, "dynamic")) return .dynamic;
    if (std.mem.eql(u8, raw, "off")) return null;
    std.debug.panic("invalid linkage '{s}': expected 'static', 'dynamic', or 'off'", .{raw});
}

/// Same as `parseLinkage` but for options with no "off" variant (libc can't
/// be turned off -- every executable needs one).
fn parseRequiredLinkage(raw: []const u8) Linkage {
    if (std.mem.eql(u8, raw, "static")) return .static;
    if (std.mem.eql(u8, raw, "dynamic")) return .dynamic;
    std.debug.panic("invalid linkage '{s}': expected 'static' or 'dynamic'", .{raw});
}

/// Libs that can actually be built from source and statically linked in.
/// Everything else in `lib_names` still only supports "dynamic"/"off".
const static_implemented = std.StaticStringMap(void).initComptime(.{
    .{"zlib"}, .{"openssl"}, .{"libffi"},
});

/// Default linkage per lib: mirrors python-build-standalone (pbs, what `uv`
/// ships) for now -- pbs statically embeds every one of these except tk into
/// its `libpython`, keeping only `_tkinter` as an external dlopen'd `.so`
/// (see dynlibs.md §6). We default to "static" wherever that's actually
/// implemented (`static_implemented`) and fall back to "dynamic" -- stock
/// CPython's own auto-detect-and-link behavior -- for the rest, until static
/// support for them lands too.
const default_overrides = std.StaticStringMap([]const u8).initComptime(.{
    .{ "zlib", "static" },
    .{ "openssl", "static" },
    .{ "libffi", "static" },
});

/// Reads `-D{lib}-linkage=...` for every third-party dependency (see
/// `default_overrides` for per-lib defaults). Panics on "static" for libs
/// not in `static_implemented`: nothing builds those from source yet.
pub fn parseOptions(b: *std.Build) BuildOptions {
    var options: BuildOptions = undefined;
    inline for (lib_names) |name| {
        const default = default_overrides.get(name) orelse "dynamic";
        const raw = b.option(
            []const u8,
            name ++ "-linkage",
            b.fmt("Linkage for " ++ name ++ ": static, dynamic, or off (default: {s})", .{default}),
        ) orelse default;
        const linkage = parseLinkage(raw);
        if (linkage) |l| if (l == .static and !static_implemented.has(name))
            std.debug.panic(name ++ "-linkage=static: static linking not implemented yet", .{});
        @field(options, name ++ "_linkage") = linkage;
    }

    const libc_raw = b.option(
        []const u8,
        "libc-linkage",
        "Linkage for libc: static or dynamic (default: dynamic)",
    ) orelse "dynamic";
    options.libc_linkage = parseRequiredLinkage(libc_raw);

    const python_raw = b.option(
        []const u8,
        "python-linkage",
        "Linkage for the core interpreter library: static, dynamic, or off (default: off)",
    ) orelse "off";
    options.python_linkage = parseLinkage(python_raw);

    options.strip = b.option(
        bool,
        "strip",
        "Strip debug info and symbols from the produced artifacts (default: Zig's per-optimize-mode default)",
    );

    options.pyconfig_header = b.option(
        []const u8,
        "pyconfig-header",
        "Path to an existing pyconfig.h to use instead of the one ./configure generates",
    );

    const static_modules_raw = b.option(
        []const u8,
        "static-modules",
        "Comma-separated module names to compile as builtins (no dlopen) instead of shared .so's",
    ) orelse "";
    var static_modules: std.ArrayList([]const u8) = .empty;
    var static_modules_it = std.mem.splitScalar(u8, static_modules_raw, ',');
    while (static_modules_it.next()) |name| {
        if (name.len > 0) static_modules.append(b.allocator, name) catch @panic("OOM");
    }
    options.static_modules = static_modules.items;

    const disabled_modules_raw = b.option(
        []const u8,
        "disabled-modules",
        "Comma-separated module names to skip entirely (no .so, no builtin) -- for modules with no linkage knob of their own",
    ) orelse "";
    var disabled_modules: std.ArrayList([]const u8) = .empty;
    var disabled_modules_it = std.mem.splitScalar(u8, disabled_modules_raw, ',');
    while (disabled_modules_it.next()) |name| {
        if (name.len > 0) disabled_modules.append(b.allocator, name) catch @panic("OOM");
    }
    options.disabled_modules = disabled_modules.items;

    if (options.python_linkage == .dynamic and options.libc_linkage == .static)
        std.debug.panic(
            "python-linkage=dynamic requires libc-linkage=dynamic: a statically " ++
                "linked executable has no dynamic section at all, so it can't " ++
                "have an ordinary build-time dependency on a shared library. " ++
                "Use python-linkage=static, or libc-linkage=dynamic.",
            .{},
        );

    // The only two shapes left once the .dynamic+.static combo above is
    // ruled out: "off" (one monolithic exe) and "static" (a libpythonX.Y.a
    // that still ends up fully absorbed into one monolithic exe -- see
    // addPythonLib). Both rely on `-rdynamic` for extension modules to
    // resolve Python C-API symbols against the exe; `libc-linkage=static`
    // strips the exe's dynamic symbol table entirely, breaking that for
    // every dlopen()'d extension. Only `python-linkage=dynamic` (a real
    // libpythonX.Y.so) avoids this -- and that combination already panics
    // above rather than reaching here.
    if (options.libc_linkage == .static) std.debug.print(
        "warning: libc-linkage=static with python-linkage={s} produces an " ++
            "executable with no usable dynamic symbol table -- every " ++
            "dlopen()'d extension module (zlib, ssl, sqlite3, ctypes, " ++
            "_socket, ...) will fail to import with 'undefined symbol'. Only " ++
            "core/frozen stdlib works. Use python-linkage=dynamic (which " ++
            "requires libc-linkage=dynamic) to keep extensions working. See " ++
            "README.md's \"libc vs. python linkage\" section.\n",
        .{if (options.python_linkage == .static) "static" else "off"},
    );

    return options;
}

const ModuleDeps = struct {
    linkage_field: []const u8,
    modules: []const []const u8,
};

/// Which CPython extension module(s) each dependency's linkage option gates.
const module_deps = [_]ModuleDeps{
    .{ .linkage_field = "openssl_linkage", .modules = &.{ "_ssl", "_hashlib" } },
    .{ .linkage_field = "libffi_linkage", .modules = &.{"_ctypes"} },
    .{ .linkage_field = "ncurses_linkage", .modules = &.{ "_curses", "_curses_panel" } },
    .{ .linkage_field = "readline_linkage", .modules = &.{"readline"} },
    .{ .linkage_field = "sqlite_linkage", .modules = &.{"_sqlite3"} },
    // `binascii` also links libz (crc32) alongside the `zlib` module itself
    // -- see dynlibs.md's "C ext: zlib, binascii" note. Gate both here, not
    // just `zlib`: `-Dzlib-linkage=off` previously left `binascii` still
    // demanding a system `libz` that was never provided, failing to compile
    // regardless of target (confirmed on `-Dtarget=x86_64-linux-musl`, but
    // the mapping gap isn't musl-specific).
    .{ .linkage_field = "zlib_linkage", .modules = &.{ "zlib", "binascii" } },
    .{ .linkage_field = "bz2_linkage", .modules = &.{"_bz2"} },
    .{ .linkage_field = "lzma_linkage", .modules = &.{"_lzma"} },
    .{ .linkage_field = "tk_linkage", .modules = &.{"_tkinter"} },
};

/// True if `name` is a third-party-backed module whose dependency is off
/// (linkage=null), or was named explicitly via `-Ddisabled-modules=...`.
pub fn isModuleDisabled(options: BuildOptions, name: []const u8) bool {
    for (options.disabled_modules) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    inline for (module_deps) |dep| {
        for (dep.modules) |m| {
            if (std.mem.eql(u8, m, name)) return @field(options, dep.linkage_field) == null;
        }
    }
    return false;
}

/// True if `name` was requested via `-Dstatic-modules=...` (see
/// `BuildOptions.static_modules`).
pub fn isModuleForcedStatic(options: BuildOptions, name: []const u8) bool {
    for (options.static_modules) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    return false;
}
