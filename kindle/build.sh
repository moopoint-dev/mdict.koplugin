#!/bin/sh
# Builds mdict.koplugin/kindle/kindle_shim.so, the library the Kindle browser test preloads
# into Amazon's browser (see src/kindle_shim.c).
#
#   kindle/build.sh
#
# Needs an ARM hard-float cross compiler (Debian/Ubuntu: gcc-arm-linux-gnueabihf) and the
# Xlib headers (libx11-dev). The browser brings its own C library (glibc 2.27 on firmware
# 5.18), so the shim links against stand-ins that offer only the old symbol versions every
# Kindle's C library has: nothing from Amazon's firmware is needed.
set -eu
cd "$(dirname "$0")"
CC=${CC:-arm-linux-gnueabihf-gcc}
STRIP=${STRIP:-arm-linux-gnueabihf-strip}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# stand-ins for libc.so.6 and libdl.so.2 that export the few functions used, at GLIBC_2.4
printf 'GLIBC_2.4 { global: getenv; syslog; strcmp; strdup; local: *; };\n' > "$tmp/libc.map"
printf 'void getenv(void){}\nvoid syslog(void){}\nvoid strcmp(void){}\nvoid strdup(void){}\n' > "$tmp/libc.c"
printf 'GLIBC_2.4 { global: dlsym; local: *; };\n' > "$tmp/libdl.map"
printf 'void dlsym(void){}\n' > "$tmp/libdl.c"
"$CC" -shared -fPIC -nostdlib -fno-builtin -Wl,-soname,libc.so.6 -Wl,--version-script="$tmp/libc.map" \
    -o "$tmp/libc.so.6" "$tmp/libc.c"
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libdl.so.2 -Wl,--version-script="$tmp/libdl.map" \
    -o "$tmp/libdl.so.2" "$tmp/libdl.c"

out=../mdict.koplugin/kindle/kindle_shim.so
mkdir -p "$(dirname "$out")"
"$CC" -shared -fPIC -O2 -Wall -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -fno-stack-protector -nostdlib \
    -ffile-prefix-map="$PWD"=. -o "$out" src/kindle_shim.c "$tmp/libc.so.6" "$tmp/libdl.so.2" -lgcc
"$STRIP" --strip-unneeded "$out"
echo "$out"
