#!/bin/bash
# 隔離属性を外す中核が壊れたら失敗する、いちばん小さい確認。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/dist/WarnOff.app/Contents/MacOS/WarnOff"
test -x "$BIN"
test -s "$ROOT/dist/WarnOff.app/Contents/Resources/AppIcon.icns"
test -s "$ROOT/dist/WarnOff.app/Contents/Resources/en.lproj/Localizable.strings"
test -s "$ROOT/dist/WarnOff.app/Contents/Resources/ja.lproj/Localizable.strings"
test -s "$ROOT/dist/WarnOff.app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
test -s "$ROOT/dist/WarnOff.app/Contents/Resources/zh-Hant.lproj/Localizable.strings"
"$BIN" --self-test

TMP="$(mktemp -d /tmp/warnoff.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "hello" > "$TMP/sample.zip"
mkdir -p "$TMP/Dummy.app/Contents"
echo "ok" > "$TMP/Dummy.app/Contents/Info.plist"
echo "hello" > "$TMP/skip.txt"
mkdir -p "$TMP/Foo.dmg.download"
echo "partial" > "$TMP/Foo.dmg.download/Foo.dmg"
xattr -w com.apple.quarantine "0081;00000000;Safari;selfcheck" "$TMP/Foo.dmg.download/Foo.dmg"

mkdir -p "$TMP/Inner.app/Contents/MacOS"
echo "bin" > "$TMP/Inner.app/Contents/MacOS/bin"
xattr -w com.apple.quarantine "0081;00000000;Safari;selfcheck" "$TMP/Inner.app/Contents/MacOS/bin"

# ダウンロード途中の名前は触らない
echo "partial" > "$TMP/late.dmg.crdownload"
xattr -w com.apple.quarantine "0081;00000000;Safari;selfcheck" "$TMP/late.dmg.crdownload"

xattr -w com.apple.quarantine "0081;00000000;Safari;selfcheck" "$TMP/sample.zip"
xattr -w com.apple.quarantine "0081;00000000;Safari;selfcheck" "$TMP/Dummy.app"
xattr -w com.apple.quarantine "0081;00000000;Safari;selfcheck" "$TMP/skip.txt"

OUT="$("$BIN" --once "$TMP")"
echo "$OUT"
test "$OUT" = "cleared 3"

if xattr -p com.apple.quarantine "$TMP/sample.zip" >/dev/null 2>&1; then
  echo "FAIL: zip still quarantined" >&2
  exit 1
fi
if xattr -p com.apple.quarantine "$TMP/Dummy.app" >/dev/null 2>&1; then
  echo "FAIL: app still quarantined" >&2
  exit 1
fi
if ! xattr -p com.apple.quarantine "$TMP/skip.txt" >/dev/null 2>&1; then
  echo "FAIL: skip.txt should keep quarantine" >&2
  exit 1
fi
if ! xattr -p com.apple.quarantine "$TMP/late.dmg.crdownload" >/dev/null 2>&1; then
  echo "FAIL: incomplete download should keep quarantine" >&2
  exit 1
fi
if ! xattr -p com.apple.quarantine "$TMP/Foo.dmg.download/Foo.dmg" >/dev/null 2>&1; then
  echo "FAIL: nested incomplete dmg should keep quarantine" >&2
  exit 1
fi
if xattr -p com.apple.quarantine "$TMP/Inner.app/Contents/MacOS/bin" >/dev/null 2>&1; then
  echo "FAIL: inner app executable still quarantined" >&2
  exit 1
fi

MISSING_OUT="$("$BIN" --once "$TMP/does-not-exist")"
echo "$MISSING_OUT"
test "$MISSING_OUT" = "cleared 0"

echo "selfcheck ok"
