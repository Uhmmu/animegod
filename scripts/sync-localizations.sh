#!/bin/sh
# Pulls the strings extracted by the last build into the String Catalogs.
# Xcode does this on its own when building in the IDE; command-line builds
# only write .stringsdata, so run this after one:
#
#   xcodebuild … -derivedDataPath DerivedData/<task> build
#   scripts/sync-localizations.sh DerivedData/<task>
set -eu
derived="${1:?usage: $0 <derived data path>}"
intermediates="$derived/Build/Intermediates.noindex"

sync() {
    catalog="$1"; target_glob="$2"
    # One architecture is enough: both slices extract the same strings.
    # The glob is unquoted on purpose — the iOS target's build directory is
    # nested inside the project's, so "AnimeGod.build" alone would sweep the
    # phone's strings into the Mac's catalog.
    # shellcheck disable=SC2086
    files=$(find $intermediates/$target_glob -path '*/arm64/*' -name '*.stringsdata' 2>/dev/null)
    [ -n "$files" ] || { echo "no .stringsdata under $target_dir — build first" >&2; exit 1; }
    args=""
    for f in $files; do args="$args --stringsdata $f"; done
    # shellcheck disable=SC2086
    xcrun xcstringstool sync "$catalog" $args
    echo "synced $catalog ($(echo "$files" | wc -l | tr -d ' ') files)"
}

sync App/Localizable.xcstrings 'AnimeGod.build/*/AnimeGod.build'
sync Sources/AnimeGodCore/Resources/Localizable.xcstrings AnimeGodCore.build
sync Mobile/Localizable.xcstrings 'AnimeGod.build/*/AnimeGodMobile.build'
