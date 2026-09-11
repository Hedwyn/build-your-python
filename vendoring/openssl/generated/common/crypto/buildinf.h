/*
 * Static replacement for util/mkbuildinf.pl's output -- this project builds
 * OpenSSL from a fixed source list via Zig, not via OpenSSL's own Makefile,
 * so there is no `$(CC) $(LIB_CFLAGS)` to capture. Content is purely
 * cosmetic (surfaced only through OpenSSL_version()/SSLeay_version()-style
 * strings), same as upstream's own generated file.
 *
 * Copyright 2014-2017 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

#define PLATFORM "platform: meta-python (zig cc, no-asm)"
#define DATE "built on: reproducible build (date omitted)"

static const char compiler_flags[] = "compiler: zig cc -DOPENSSL_NO_ASM";
