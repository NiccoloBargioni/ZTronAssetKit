#!/bin/bash
cd "$(dirname "$0")"
R=Sources/ZTronAssetModel/Manifest/Decoding/ManifestRules.swift
run() { # label old new
  cp orig/ManifestRules.swift.head $R
  python3 mutate.py $R "$2" "$3" || { echo "$1 apply failed"; return; }
  bash run.sh "$1"
  cp orig/ManifestRules.swift.head $R
}
run M1b-no-backslash ' || byte == UInt8(ascii: "\\")' ''
run M1c-no-pct2E 'return utf8[start] == UInt8(ascii: "%") && utf8[start + 1] == UInt8(ascii: "2") && utf8[start + 2] | 0x20 == UInt8(ascii: "e")' 'return false'
run M1d-no-trailing '                || ManifestRules.isUnnamedSegment(utf8, from: slashSegmentStart, to: pathEnd))' '                )'
run M1e-checkedFrom0 'let checkedFrom = authority ? hierarchyStart + 2 : (absolute ? 1 : 0)' 'let checkedFrom = 0'
run M1f-no-empty '        case 0:
            return true' '        case 0:
            return false'
run M1g-no-dot '            return utf8[start] == UInt8(ascii: ".")' '            return false'
echo ALLDONE
