dnl icecreme's configure.ac -- resolves everything the Makefile used to
dnl compute itself via `!=` shell-assignment (pkg-config lookups, an
dnl EXECINFO_LIBS uname check) into concrete, already-substituted values.
dnl
dnl Why this exists at all: `!=` is supported by real BSD make (always)
dnl and by GNU Make >= 4.0, but NOT by GNU Make 3.81 -- the last GPLv2
dnl release, which is what Apple ships (frozen, for licensing reasons) as
dnl macOS's stock /usr/bin/make. A single Makefile can't paper over that
dnl with GNU's `$(shell ...)` either. since that function doesn't exist in
dnl BSD make at all -- the two flavors this project supports have disjoint
dnl feature sets for "run a shell command and capture its output" with no
dnl overlapping syntax. Resolving these values in `configure`'s own POSIX
dnl shell (which runs identically everywhere, no Make involved) sidesteps
dnl the conflict entirely for anything that's a fixed build-time constant.
dnl
dnl HDRS/ICECREME_COMPILER_SLDS are the one exception -- they enumerate the
dnl CURRENT source tree (headers, .sld files), which changes as the repo
dnl grows, so baking a list into config.status output would go stale the
dnl moment a file is added without rerunning configure. Those two stay
dnl dynamic on every `make` invocation; see the MAKE_SUPPORTS_BANG_EQ probe
dnl below, which instead detects which syntax THIS make binary supports
dnl and substitutes the right one, and the CREME_WITH_*-gated LDLIBS
dnl (SQL/SSL/FFI/YAML/CRYPTO) below, which need no probe at all -- see the
dnl LDLIBS_GATED_SH comment in Makefile.in for why.
AC_PREREQ([2.69])
AC_INIT([icecreme], [0])
AC_CONFIG_FILES([Makefile])
AC_CONFIG_HEADERS([config.h])

AC_PROG_CC
# Strip any -std=... AC_PROG_CC folded directly into $CC (recent autoconf
# probes for "a reasonably modern C dialect" and appends it there instead of
# to CFLAGS) -- CREME_CFLAGS below already pins -std=c11 explicitly, so a
# second, different -std flag riding along in $(CC) itself is redundant at
# best and a silent conflict at worst.
CC=`echo "$CC" | sed 's/ .*//'`
AC_PATH_PROG([PKG_CONFIG], [pkg-config], [])

# pkgcfg(MODULE, FALLBACK_LIBS) -- looks up MODULE via pkg-config when
# available, else falls back to FALLBACK_LIBS for the link flags and an
# empty cflags (matching the Makefile's own prior `|| echo -lxxx` idiom).
# Sets $pkgcfg_cflags/$pkgcfg_libs as the two out-params, since AC_SUBST
# needs distinct variable names per call site.
pkgcfg () {
  module="$1"; fallback_libs="$2"
  if test -n "$PKG_CONFIG" && "$PKG_CONFIG" --exists "$module" 2>/dev/null; then
    pkgcfg_cflags=`"$PKG_CONFIG" --cflags "$module" 2>/dev/null`
    pkgcfg_libs=`"$PKG_CONFIG" --libs "$module" 2>/dev/null`
  else
    pkgcfg_cflags=""
    pkgcfg_libs="$fallback_libs"
  fi
}

# Boehm GC -- bdw-gc-threaded (actor.c needs GC_register_my_thread/etc.,
# compiled out of a plain, non-threaded libgc) falling back to plain
# bdw-gc for distros that bake pthread support into their one package.
# -DGC_THREADS is unconditional either way -- see Makefile.in's own note.
AC_MSG_CHECKING([for Boehm GC])
if test -n "$PKG_CONFIG" && "$PKG_CONFIG" --exists bdw-gc-threaded 2>/dev/null; then
  GC_PKG_CFLAGS=`"$PKG_CONFIG" --cflags bdw-gc-threaded`
  GC_LIBS=`"$PKG_CONFIG" --libs bdw-gc-threaded`
  AC_MSG_RESULT([bdw-gc-threaded])
elif test -n "$PKG_CONFIG" && "$PKG_CONFIG" --exists bdw-gc 2>/dev/null; then
  GC_PKG_CFLAGS=`"$PKG_CONFIG" --cflags bdw-gc`
  GC_LIBS=`"$PKG_CONFIG" --libs bdw-gc`
  AC_MSG_RESULT([bdw-gc])
else
  GC_PKG_CFLAGS=""
  GC_LIBS="-lgc"
  AC_MSG_RESULT([assuming -lgc (pkg-config lookup failed)])
fi
AC_SUBST([GC_PKG_CFLAGS])
AC_SUBST([GC_LIBS])

pkgcfg libpcre2-8 -lpcre2-8
PCRE2_CFLAGS=$pkgcfg_cflags; PCRE2_LIBS=$pkgcfg_libs
AC_SUBST([PCRE2_CFLAGS])
AC_SUBST([PCRE2_LIBS])

pkgcfg gmp -lgmp
GMP_CFLAGS=$pkgcfg_cflags; GMP_LIBS=$pkgcfg_libs
AC_SUBST([GMP_CFLAGS])
AC_SUBST([GMP_LIBS])

# _RAW: link-time inclusion is gated by CREME_WITH_* at Make time, not here
# (see Makefile.in's LDLIBS_GATED_SH) -- configure only resolves WHAT the
# flags would be, not WHETHER they're used.
pkgcfg libcrypto -lcrypto
CRYPTO_CFLAGS=$pkgcfg_cflags; CRYPTO_LIBS_RAW=$pkgcfg_libs
AC_SUBST([CRYPTO_CFLAGS])
AC_SUBST([CRYPTO_LIBS_RAW])

pkgcfg libssl -lssl
SSL_CFLAGS=$pkgcfg_cflags; SSL_LIBS_RAW=$pkgcfg_libs
AC_SUBST([SSL_CFLAGS])
AC_SUBST([SSL_LIBS_RAW])

pkgcfg libffi -lffi
FFI_CFLAGS=$pkgcfg_cflags; FFI_LIBS=$pkgcfg_libs
AC_SUBST([FFI_CFLAGS])
AC_SUBST([FFI_LIBS])

pkgcfg yaml-0.1 -lyaml
YAML_CFLAGS=$pkgcfg_cflags; YAML_LIBS=$pkgcfg_libs
AC_SUBST([YAML_CFLAGS])
AC_SUBST([YAML_LIBS])

pkgcfg libzstd -lzstd
ZSTD_CFLAGS=$pkgcfg_cflags; ZSTD_LIBS=$pkgcfg_libs
AC_SUBST([ZSTD_CFLAGS])
AC_SUBST([ZSTD_LIBS])

# backtrace(3)/execinfo.h ship inside libc on Linux/glibc and Darwin, but
# FreeBSD splits them into their own libexecinfo (base system, not a
# package) -- link it there only. A real link-test (does backtrace() need
# an extra -l at all, and if so which) rather than a hardcoded FreeBSD-name
# check -- same reasoning as HAVE_CLOSEFROM below: testing for the actual
# feature, not guessing it from a platform name, is what catches a case
# like process.c's old __APPLE__-assumed-to-have-closefrom bug before it
# ships, instead of after. ACTION-IF-FOUND overrides AC_SEARCH_LIBS's own
# default of prepending the found lib to $LIBS (global, every binary) --
# EXECINFO_LIBS stays its own substitution instead, same as every other
# *_LIBS above.
AC_SEARCH_LIBS([backtrace], [execinfo], [
  AS_IF([test "x$ac_cv_search_backtrace" = "xnone required"],
        [EXECINFO_LIBS=""],
        [EXECINFO_LIBS="$ac_cv_search_backtrace"])
], [
  AC_MSG_WARN([backtrace(3) not found -- profiler.c's SIGPROF sampler needs it])
  EXECINFO_LIBS=""
])
AC_SUBST([EXECINFO_LIBS])

# process.c's close_inherited_fds() used to assume every BSD-derived
# __APPLE__/__FreeBSD__/__NetBSD__/__OpenBSD__/__DragonFly__ has closefrom(3)
# -- wrong for Darwin specifically (its SDK headers never declare it), which
# only surfaced as a build failure on macOS. A real function-existence check
# (-> HAVE_CLOSEFROM in config.h, #ifdef'd in process.c) fixes the whole bug
# class instead of hardcoding one more corrected platform list: whichever
# platforms genuinely have it get the fast path, automatically, with no
# per-platform-name guesswork to keep in sync as new platforms show up.
AC_CHECK_FUNCS([closefrom])

# ---- Optional native builtin families (icecreme/builtin_config.h) ---------
# One --enable-X/--disable-X pair per family, default enabled -- matching
# every prior release's "everything always in" behavior. These used to be
# plain Make `?=` defaults (`make CREME_WITH_SQL=0 ...`), which still works
# exactly as before: a variable given on the `make` command line always
# overrides an in-Makefile assignment regardless of operator (`=` or `?=`),
# so moving the DEFAULT here to configure doesn't take that override away --
# it just makes the choice persistent/discoverable (`./configure --help`)
# instead of a one-off flag you have to remember to repeat on every `make`
# invocation. See examples/libcream/Makefile for a trimmed-library consumer
# of the Make-time override, and icecreme/README.md's "Embedding" section
# for the full family list.
#
# to_01 turns configure's own yes/no into the 1/0 these families' C
# preprocessor guards (`#if CREME_WITH_<NAME>`) and the LDLIBS_GATED_SH
# shell tests in Makefile.in (`[ "$(CREME_WITH_SQL)" != 0 ]`) both expect.
to_01 () { test "x$1" = xno && echo 0 || echo 1; }

AC_ARG_ENABLE([sql], [AS_HELP_STRING([--disable-sql], [disable (creme sql) -- SQLite bindings])], [], [enable_sql=yes])
CREME_WITH_SQL=`to_01 "$enable_sql"`
AC_SUBST([CREME_WITH_SQL])

AC_ARG_ENABLE([http], [AS_HELP_STRING([--disable-http], [disable (creme http) -- HTTP client/server, TLS via libssl])], [], [enable_http=yes])
CREME_WITH_HTTP=`to_01 "$enable_http"`
AC_SUBST([CREME_WITH_HTTP])

AC_ARG_ENABLE([cipher], [AS_HELP_STRING([--disable-cipher], [disable (creme cipher) -- symmetric encryption via libcrypto])], [], [enable_cipher=yes])
CREME_WITH_CIPHER=`to_01 "$enable_cipher"`
AC_SUBST([CREME_WITH_CIPHER])

AC_ARG_ENABLE([pkey], [AS_HELP_STRING([--disable-pkey], [disable (creme pkey) -- asymmetric keys via libcrypto])], [], [enable_pkey=yes])
CREME_WITH_PKEY=`to_01 "$enable_pkey"`
AC_SUBST([CREME_WITH_PKEY])

AC_ARG_ENABLE([x509], [AS_HELP_STRING([--disable-x509], [disable (creme x509) -- X.509 certificates via libcrypto])], [], [enable_x509=yes])
CREME_WITH_X509=`to_01 "$enable_x509"`
AC_SUBST([CREME_WITH_X509])

AC_ARG_ENABLE([digest], [AS_HELP_STRING([--disable-digest], [disable (creme digest) -- hash functions via libcrypto])], [], [enable_digest=yes])
CREME_WITH_DIGEST=`to_01 "$enable_digest"`
AC_SUBST([CREME_WITH_DIGEST])

AC_ARG_ENABLE([secure-random], [AS_HELP_STRING([--disable-secure-random], [disable (creme secure-random) -- CSPRNG via libcrypto])], [], [enable_secure_random=yes])
CREME_WITH_SECURE_RANDOM=`to_01 "$enable_secure_random"`
AC_SUBST([CREME_WITH_SECURE_RANDOM])

AC_ARG_ENABLE([actor], [AS_HELP_STRING([--disable-actor], [disable (creme actor) -- actor/supervision runtime, needs libcrypto's HMAC handshake])], [], [enable_actor=yes])
CREME_WITH_ACTOR=`to_01 "$enable_actor"`
AC_SUBST([CREME_WITH_ACTOR])

AC_ARG_ENABLE([ffi], [AS_HELP_STRING([--disable-ffi], [disable (creme ffi) -- libffi dynamic FFI bridge])], [], [enable_ffi=yes])
CREME_WITH_FFI=`to_01 "$enable_ffi"`
AC_SUBST([CREME_WITH_FFI])

AC_ARG_ENABLE([yaml], [AS_HELP_STRING([--disable-yaml], [disable (creme yaml) -- YAML read/write via libyaml])], [], [enable_yaml=yes])
CREME_WITH_YAML=`to_01 "$enable_yaml"`
AC_SUBST([CREME_WITH_YAML])

AC_ARG_ENABLE([mux], [AS_HELP_STRING([--disable-mux], [disable (creme mux) -- HTTP/1.1 connection multiplexer])], [], [enable_mux=yes])
CREME_WITH_MUX=`to_01 "$enable_mux"`
AC_SUBST([CREME_WITH_MUX])

AC_ARG_ENABLE([csv], [AS_HELP_STRING([--disable-csv], [disable (creme csv) -- CSV read/write])], [], [enable_csv=yes])
CREME_WITH_CSV=`to_01 "$enable_csv"`
AC_SUBST([CREME_WITH_CSV])

AC_ARG_ENABLE([treelist], [AS_HELP_STRING([--disable-treelist], [disable (creme treelist)])], [], [enable_treelist=yes])
CREME_WITH_TREELIST=`to_01 "$enable_treelist"`
AC_SUBST([CREME_WITH_TREELIST])

AC_ARG_ENABLE([json], [AS_HELP_STRING([--disable-json], [disable (creme json) -- JSON read/write])], [], [enable_json=yes])
CREME_WITH_JSON=`to_01 "$enable_json"`
AC_SUBST([CREME_WITH_JSON])

AC_ARG_ENABLE([bigdecimal], [AS_HELP_STRING([--disable-bigdecimal], [disable (creme bigdecimal) -- arbitrary-precision decimals])], [], [enable_bigdecimal=yes])
CREME_WITH_BIGDECIMAL=`to_01 "$enable_bigdecimal"`
AC_SUBST([CREME_WITH_BIGDECIMAL])

AC_ARG_ENABLE([term], [AS_HELP_STRING([--disable-term], [disable (creme term) -- terminal/TTY control])], [], [enable_term=yes])
CREME_WITH_TERM=`to_01 "$enable_term"`
AC_SUBST([CREME_WITH_TERM])

AC_ARG_ENABLE([process], [AS_HELP_STRING([--disable-process], [disable (creme process) -- subprocess spawn/pipe])], [], [enable_process=yes])
CREME_WITH_PROCESS=`to_01 "$enable_process"`
AC_SUBST([CREME_WITH_PROCESS])

AC_ARG_ENABLE([string], [AS_HELP_STRING([--disable-string], [disable (creme string) -- growable string builder])], [], [enable_string=yes])
CREME_WITH_STRING=`to_01 "$enable_string"`
AC_SUBST([CREME_WITH_STRING])

# Which shell-output syntax THIS make binary supports -- BSD make and GNU
# Make >= 4.0 understand `!=`; GNU Make < 4.0 (Apple's stock macOS make)
# doesn't, but has `$(wildcard ...)`/`$(shell ...)` instead (which BSD make
# lacks). HDRS/ICECREME_COMPILER_SLDS need genuinely dynamic, per-build
# evaluation (see this file's header comment), so probe once here and
# substitute whichever syntax actually works for the make that's about to
# run this Makefile.
AC_MSG_CHECKING([whether \$(MAKE) supports != shell-assignment])
: "${MAKE:=make}"
bang_eq_probe=`cat <<'EOF'
V != echo bang-eq-ok
all:
	@echo "$(V)"
EOF
`
bang_eq_result=`printf '%s\n' "$bang_eq_probe" | "$MAKE" -f - 2>/dev/null`
if test "$bang_eq_result" = "bang-eq-ok"; then
  HDRS_ASSIGN="!= echo *.h"
  SLDS_ASSIGN="!= find ../modules/creme -name '*.sld' | tr '\\n' ' '"
  AC_MSG_RESULT([yes])
else
  HDRS_ASSIGN="= \$(wildcard *.h)"
  SLDS_ASSIGN="= \$(shell find ../modules/creme -name '*.sld' | tr '\\n' ' ')"
  AC_MSG_RESULT([no (falling back to GNU \$(wildcard)/\$(shell))])
fi
AC_SUBST([HDRS_ASSIGN])
AC_SUBST([SLDS_ASSIGN])

AC_OUTPUT
