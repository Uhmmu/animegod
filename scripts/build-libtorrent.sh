#!/bin/bash
# Builds libtorrent-rasterbar and OpenSSL as Universal (arm64 + x86_64)
# static libraries for the embedded download engine.
#
#   ./scripts/build-libtorrent.sh
#
# Output (gitignored, ~1 GB of intermediates, minutes to build):
#   Vendor/libtorrent/include/…      libtorrent + OpenSSL headers
#   Vendor/libtorrent/lib/*.a        universal static libraries
#
# Boost headers come from Homebrew (header-only since 1.69, so one copy
# serves both architectures). Only the sources below are downloaded, over
# HTTPS, and each is checked against a pinned SHA-256 before it is used.
set -euo pipefail

LIBTORRENT_VERSION="2.0.14"
LIBTORRENT_SHA256="1b0b21b9755b5fbec23ca9ba2d2d10434ecb6711c39f37f5fc9d5aa25cf369c9"
OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"
DEPLOYMENT_TARGET="14.0"
ARCHS=(arm64 x86_64)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/src"
BUILD="$VENDOR/build"
OUT="$VENDOR/libtorrent"
BOOST_INCLUDE="$(brew --prefix boost 2>/dev/null)/include"

[ -d "$BOOST_INCLUDE/boost" ] || { echo "Boost headers not found — run: brew install boost" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found — run: brew install cmake" >&2; exit 1; }

mkdir -p "$SRC" "$BUILD" "$OUT/lib"

fetch() { # url sha256 filename
    local url="$1" sha="$2" file="$SRC/$3"
    if [ ! -f "$file" ]; then
        echo "→ downloading $3"
        curl -fsSL -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    echo "$sha  $file" | shasum -a 256 -c - >/dev/null \
        || { echo "checksum mismatch for $3 — refusing to build" >&2; exit 1; }
}

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
      "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz"
fetch "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" \
      "$LIBTORRENT_SHA256" "libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"

[ -d "$SRC/openssl-$OPENSSL_VERSION" ] || tar -xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$SRC"
[ -d "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION" ] || tar -xzf "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" -C "$SRC"

for arch in "${ARCHS[@]}"; do
    ssl_prefix="$BUILD/openssl-$arch"
    if [ ! -f "$ssl_prefix/lib/libcrypto.a" ]; then
        echo "→ building OpenSSL for $arch"
        rm -rf "$BUILD/openssl-src-$arch"
        cp -R "$SRC/openssl-$OPENSSL_VERSION" "$BUILD/openssl-src-$arch"
        (
            cd "$BUILD/openssl-src-$arch"
            # libdir=lib keeps arm64 and x86_64 layouts identical (the
            # default is lib64 on some targets).
            ./Configure "darwin64-$arch-cc" no-shared no-tests no-docs no-apps \
                --prefix="$ssl_prefix" --libdir=lib \
                "-mmacosx-version-min=$DEPLOYMENT_TARGET" >/dev/null
            make -j"$(sysctl -n hw.ncpu)" >/dev/null
            make install_sw >/dev/null
        )
    fi

    lt_build="$BUILD/libtorrent-$arch"
    if [ ! -f "$lt_build/libtorrent-rasterbar.a" ]; then
        echo "→ building libtorrent for $arch"
        cmake -S "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION" -B "$lt_build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            -DCMAKE_CXX_STANDARD=17 \
            -DBUILD_SHARED_LIBS=OFF \
            -Dstatic_runtime=OFF \
            -Dbuild_tests=OFF \
            -Dbuild_examples=OFF \
            -Dbuild_tools=OFF \
            -Dpython-bindings=OFF \
            -DBoost_INCLUDE_DIR="$BOOST_INCLUDE" \
            -DOPENSSL_ROOT_DIR="$ssl_prefix" \
            -DOPENSSL_USE_STATIC_LIBS=ON >/dev/null
        cmake --build "$lt_build" --parallel "$(sysctl -n hw.ncpu)" >/dev/null
    fi
done

echo "→ combining universal libraries"
for lib in libtorrent-rasterbar.a:libtorrent-@ARCH@/libtorrent-rasterbar.a \
           libssl.a:openssl-@ARCH@/lib/libssl.a \
           libcrypto.a:openssl-@ARCH@/lib/libcrypto.a; do
    name="${lib%%:*}"
    pattern="${lib#*:}"
    inputs=()
    for arch in "${ARCHS[@]}"; do
        inputs+=("$BUILD/${pattern//@ARCH@/$arch}")
    done
    lipo -create "${inputs[@]}" -output "$OUT/lib/$name"
done

echo "→ copying headers"
rm -rf "$OUT/include"
mkdir -p "$OUT/include"
cp -R "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION/include/libtorrent" "$OUT/include/"
# Generated per build (export macros, version); identical for both arches.
cp -R "$BUILD/libtorrent-${ARCHS[0]}/include/libtorrent/"* "$OUT/include/libtorrent/" 2>/dev/null || true
cp -R "$BUILD/openssl-${ARCHS[0]}/include/openssl" "$OUT/include/"
# libtorrent's public headers include Boost headers, so the app needs them
# too. Copying them here keeps the Xcode build independent of Homebrew's
# location (/opt/homebrew on Apple silicon, /usr/local on Intel).
cp -RL "$BOOST_INCLUDE/boost" "$OUT/include/"
cp -R "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION/deps/try_signal/"*.hpp "$OUT/include/" 2>/dev/null || true

cat > "$OUT/BUILD_INFO.txt" <<EOF
libtorrent-rasterbar $LIBTORRENT_VERSION
openssl $OPENSSL_VERSION
boost headers: $(sed -n 's/.*BOOST_LIB_VERSION "\(.*\)".*/\1/p' "$BOOST_INCLUDE/boost/version.hpp")
architectures: ${ARCHS[*]}
deployment target: $DEPLOYMENT_TARGET
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo
lipo -info "$OUT/lib/"*.a
cat "$OUT/BUILD_INFO.txt"
