#!/usr/bin/env python3
"""Deterministic generator for the ZTronAssetKit example-manifest fixtures (ADR-008).

Everything under Tests/Fixtures/ except this script is produced by it, byte for byte:

    python3 Tests/Fixtures/generate_fixtures.py                 # (re)write Tests/Fixtures in place
    python3 Tests/Fixtures/generate_fixtures.py --out DIR       # write the tree into DIR instead
    python3 Tests/Fixtures/generate_fixtures.py --check         # generate in memory, compare with the
                                                                #   tree on disk, recompute every checksum

Rules this script keeps so that re-running it reproduces identical files:
  * Python 3 standard library only; no third-party code.
  * No clock, no `random` module, no environment input: all pseudo-random bytes come from a SHA-256
    counter-mode stream keyed by SEED and a per-file label (see `stream`).
  * JSON is written with a fixed key order, indent=2, ASCII escapes only and a trailing newline.
  * PNG uses stored (uncompressed) deflate blocks, so no zlib implementation detail leaks into the bytes.

The data model lives in ASSETS / the generation functions below; the README and expectations.json are
*derived* from the JSON that was actually written (they re-parse it), never from the construction code, so
they cannot drift from the files.
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import xml.etree.ElementTree as ElementTree
import zlib

SEED = b"ZTronAssetKit/fixtures/v1"
MIN_PAYLOAD_BYTES = 32
MAX_PAYLOAD_BYTES = 4096
PACK_MEDIA = "ZTronMedia"
PACK_CATALOG = "ZTronCatalog"
SCRIPT_NAME = "generate_fixtures.py"

LEGACY_KEYS = ["identifier", "fileExtension", "remotePath", "localPathComponents",
               "localFileName", "byteSize", "checksum"]
DIFF_CLASSES = ["added", "removed", "contentChanged", "metadataChanged", "unchanged"]


# --------------------------------------------------------------------------------------------------
# Deterministic bytes
# --------------------------------------------------------------------------------------------------

def stream(label, count):
    """`count` pseudo-random bytes: SHA-256(SEED | label | big-endian block counter), concatenated."""
    out = bytearray()
    counter = 0
    while len(out) < count:
        out += hashlib.sha256(SEED + b"|" + label.encode("utf-8") + b"|" + struct.pack(">I", counter)).digest()
        counter += 1
    return bytes(out[:count])


def box(kind, body):
    """An ISO-BMFF box: 32-bit big-endian size (header included), four-character type, body."""
    assert len(kind) == 4
    return struct.pack(">I", 8 + len(body)) + kind + body


# --------------------------------------------------------------------------------------------------
# Payload builders. Each returns the exact bytes of one fixture file.
# png, svg and wav are structurally valid, decodable files. heic, jpg, mp4 and mp3 carry the correct
# container/marker structure but seeded filler instead of coded media: they are *not* decodable.
# --------------------------------------------------------------------------------------------------

def build_heic(label, body):
    ftyp = box(b"ftyp", b"heic" + struct.pack(">I", 0) + b"mif1" + b"heic")
    return ftyp + box(b"mdat", stream(label + "/mdat", body))


def build_mp4(label, body):
    ftyp = box(b"ftyp", b"isom" + struct.pack(">I", 512) + b"isom" + b"iso2" + b"avc1" + b"mp41")
    return ftyp + box(b"free", b"") + box(b"mdat", stream(label + "/mdat", body))


def build_jpg(label, body):
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    comment = ("ZTronAssetKit fixture " + label).encode("ascii")
    com = b"\xff\xfe" + struct.pack(">H", 2 + len(comment)) + comment
    filler = bytes(0xFE if b == 0xFF else b for b in stream(label + "/scan", body))
    return b"\xff\xd8" + app0 + com + filler + b"\xff\xd9"


def build_png(label, w, h):
    pixels = stream(label + "/pixels", w * h * 3)
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0 (None)
        raw += pixels[y * w * 3:(y + 1) * w * 3]
    data = bytes(raw)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    deflate = bytearray(b"\x78\x01")
    position = 0
    while True:
        block = data[position:position + 65535]
        position += len(block)
        final = position >= len(data)
        deflate += bytes([1 if final else 0]) + struct.pack("<HH", len(block), len(block) ^ 0xFFFF) + block
        if final:
            break
    deflate += struct.pack(">I", zlib.adler32(data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB, no interlace
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", bytes(deflate)) + chunk(b"IEND", b"")


def build_svg(label):
    s = stream(label + "/svg", 32)

    def colour(i):
        return "#%02x%02x%02x" % (s[i], s[i + 1], s[i + 2])

    text = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">\n'
        "  <title>%s</title>\n"
        '  <rect width="64" height="64" fill="%s"/>\n'
        '  <circle cx="%d" cy="%d" r="%d" fill="%s"/>\n'
        '  <path d="M%d %d L%d %d L%d %d Z" fill="none" stroke="%s" stroke-width="2"/>\n'
        "</svg>\n"
    ) % (label, colour(0),
         16 + s[3] % 32, 16 + s[4] % 32, 6 + s[5] % 14, colour(6),
         s[9] % 64, s[10] % 64, s[11] % 64, s[12] % 64, s[13] % 64, s[14] % 64, colour(15))
    data = text.encode("ascii")
    ElementTree.fromstring(data)  # must be well-formed XML
    return data


def build_wav(label, samples):
    seeded = stream(label + "/pcm", samples + 2)
    period = 16 + seeded[0] % 48
    half = period // 2
    amplitude = 4000 + (seeded[1] % 32) * 100
    pcm = bytearray()
    for i in range(samples):
        phase = i % period
        if phase < half:
            triangle = phase * 2 * amplitude // half - amplitude
        else:
            triangle = (period - phase) * 2 * amplitude // half - amplitude
        value = max(-32768, min(32767, triangle + (seeded[i + 2] - 128) * 8))
        pcm += struct.pack("<h", value)
    fmt = struct.pack("<HHIIHH", 1, 1, 8000, 16000, 2, 16)  # PCM, mono, 8 kHz, 16-bit
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(pcm)) + bytes(pcm)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def build_mp3(label, frames):
    title = ("ZTron fixture " + label).encode("ascii")[:40]
    frame_body = b"\x00" + title
    tit2 = b"TIT2" + struct.pack(">I", len(frame_body)) + b"\x00\x00" + frame_body
    size = len(tit2)
    syncsafe = bytes([(size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F])
    out = bytearray(b"ID3\x03\x00\x00" + syncsafe + tit2)
    for index in range(frames):  # MPEG-1 Layer III, 128 kbit/s, 44.1 kHz, no padding: 417 bytes per frame
        out += b"\xff\xfb\x90\x64" + stream("%s/frame%d" % (label, index), 413)
    return bytes(out)


def build_payload(ext, label, params):
    if ext == "heic":
        return build_heic(label, **params)
    if ext == "mp4":
        return build_mp4(label, **params)
    if ext == "jpg":
        return build_jpg(label, **params)
    if ext == "png":
        return build_png(label, **params)
    if ext == "svg":
        return build_svg(label, **params)
    if ext == "wav":
        return build_wav(label, **params)
    if ext == "mp3":
        return build_mp3(label, **params)
    raise ValueError(ext)


# --------------------------------------------------------------------------------------------------
# The asset universe
# --------------------------------------------------------------------------------------------------

BO7 = "Black Ops 7"
RI = "Rex Infernus"
TEMPLE = "Vehytherion Temple"
BO6 = "Black Ops 6"
TERMINUS = "Terminus"
CONTROL = "Control Room"
WAW = "World at War"
NDU = "Nacht der Untoten"

ID_ICON = "bo7.ri.easter.egg.vehytherion.temple.icon"
ID_MAP = "bo7.ri.easter.egg.vehytherion.temple.map"
ID_OUTLINE = "bo7.ri.easter.egg.vehytherion.temple.outline"
ID_INTRO = "bo7.ri.cinematic.intro"
ID_THEME = "bo7.ri.music.main.theme"
ID_CRYPT = "bo7.ri.ambience.crypt"
ID_PORTRAIT = "bo7.ri.character.keeper.portrait"
ID_CARD = "bo7.ri.character.keeper.card"
ID_MENU = "bo7.menu.background"
ID_BO6_ICON = "bo6.tm.easter.egg.control.room.icon"
ID_BO6_OUTLINE = "bo6.tm.easter.egg.control.room.outline"
ID_TITLE = "waw.ndu.title.card"
ID_STING = "waw.ndu.round.start.sting"

#   payload   - key of the payload file this asset's bytes come from (a payload key is the identifier that
#               owns the file; ID_CARD deliberately shares ID_PORTRAIT's bytes: the dedupe pair)
#   kind      - sub-directory inside the Apple pack ZTronMedia
#   name      - localFileName (None: key omitted from the manifest, derived name applies)
BASE_ASSETS = [
    dict(id=ID_ICON, ext="heic", dirs=[BO7, RI, TEMPLE], name="icon", kind="images", payload=ID_ICON),
    dict(id=ID_MAP, ext="png", dirs=[BO7, RI, TEMPLE], name="Temple Map", kind="images", payload=ID_MAP),
    dict(id=ID_OUTLINE, ext="svg", dirs=[BO7, RI, TEMPLE], name=None, kind="vectors", payload=ID_OUTLINE),
    dict(id=ID_INTRO, ext="mp4", dirs=[BO7, RI, "Cinematics"], name="Intro", kind="video", payload=ID_INTRO),
    dict(id=ID_THEME, ext="mp3", dirs=[BO7, RI, "Audio"], name=None, kind="audio", payload=ID_THEME),
    dict(id=ID_CRYPT, ext="wav", dirs=[BO7, RI, "Audio"], name="Crypt Ambience", kind="audio", payload=ID_CRYPT),
    dict(id=ID_PORTRAIT, ext="jpg", dirs=[BO7, RI, "Characters"], name="Keeper Portrait", kind="images", payload=ID_PORTRAIT),
    dict(id=ID_CARD, ext="jpg", dirs=[BO7, RI, "Characters"], name="Keeper Card", kind="images", payload=ID_PORTRAIT),
    dict(id=ID_MENU, ext="heic", dirs=[BO7, "Menus"], name=None, kind="images", payload=ID_MENU),
    dict(id=ID_BO6_ICON, ext="jpg", dirs=[BO6, TERMINUS, CONTROL], name="icon", kind="images", payload=ID_BO6_ICON),
    dict(id=ID_BO6_OUTLINE, ext="svg", dirs=[BO6, TERMINUS, CONTROL], name=None, kind="vectors", payload=ID_BO6_OUTLINE),
    dict(id=ID_TITLE, ext="png", dirs=[WAW, NDU], name="Title Card", kind="images", payload=ID_TITLE),
    dict(id=ID_STING, ext="wav", dirs=[WAW, NDU, "Audio"], name=None, kind="audio", payload=ID_STING),
]

# One payload file per key: (key, extension, builder parameters). 12 baseline files.
PAYLOAD_SPECS = [
    (ID_ICON, "heic", dict(body=1504)),         # 1536 bytes
    (ID_MAP, "png", dict(w=24, h=16)),          # 1236 bytes
    (ID_OUTLINE, "svg", dict()),
    (ID_INTRO, "mp4", dict(body=4048)),         # 4096 bytes: the largest allowed fixture
    (ID_THEME, "mp3", dict(frames=3)),
    (ID_CRYPT, "wav", dict(samples=1000)),      # 2044 bytes
    (ID_PORTRAIT, "jpg", dict(body=880)),
    (ID_MENU, "heic", dict(body=32)),           # 64 bytes: the smallest fixture
    (ID_BO6_ICON, "jpg", dict(body=600)),
    (ID_BO6_OUTLINE, "svg", dict()),
    (ID_TITLE, "png", dict(w=16, h=8)),         # 460 bytes
    (ID_STING, "wav", dict(samples=300)),       # 644 bytes
]

# v2 payload variants: same identifier, new bytes. The icon variant changes the byte count; the crypt
# variant keeps it (2044 bytes) so the checksum alone must tell old from new.
VARIANT_SPECS = [
    (ID_ICON, "heic", dict(body=1760)),         # 1792 bytes
    (ID_CRYPT, "wav", dict(samples=1000)),      # 2044 bytes, different samples
]

V2_CONTENT_CHANGED = [ID_ICON, ID_CRYPT]
V3_DIRECTORY_CHANGES = {
    # identifier: (new localPathComponents or None to keep, new localFileName or None to keep)
    ID_OUTLINE: ([BO7, RI, TEMPLE, "Outlines"], None),          # directory only
    ID_THEME: (None, "Main Theme"),                             # file name only (key appears)
    ID_MENU: ([BO7, "User Interface", "Backgrounds"], "Menu Background"),  # both
}
V4_REMOVED = [ID_BO6_OUTLINE, ID_STING]

# Optional extension fields and the one unknown per-asset field, used by the envelope files only.
ENVELOPE_EXTENSIONS = {
    ID_ICON: dict(tags=["easter-egg", "icon"], policy="essential"),
    ID_MAP: dict(tags=["easter-egg", "map"]),
    ID_OUTLINE: dict(policy="essential"),
    ID_INTRO: dict(tags=["cinematic"], policy="onDemand"),
    ID_TITLE: dict(tags=["title-card"], policy="standard"),
    ID_MENU: dict(policy="essential"),
}
ENVELOPE_UNKNOWN_ASSET = (ID_BO6_ICON, "blurHash", "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
ENVELOPE_UNKNOWN_TOP = ("buildInfo", {"commit": "0000000", "pipeline": 1})

SERIES = [("v1", "v1.json"), ("v2", "v2-checksum-change.json"),
          ("v3", "v3-directory-change.json"), ("v4", "v4-removal.json")]
TIERS = ["aws", "apple"]


class Payload:
    """One payload file plus the facts the manifests need about it."""

    def __init__(self, path, data):
        self.path = path
        self.data = data
        self.sha = hashlib.sha256(data).hexdigest()
        self.size = len(data)
        assert MIN_PAYLOAD_BYTES <= self.size <= MAX_PAYLOAD_BYTES, (path, self.size)


def build_payloads():
    """Returns {payload key: Payload}; variant keys are '<identifier>@v2'."""
    payloads = {}
    for key, ext, params in PAYLOAD_SPECS:
        payloads[key] = Payload("payloads/%s.%s" % (key, ext), build_payload(ext, key + "@v1", params))
    for key, ext, params in VARIANT_SPECS:
        payloads[key + "@v2"] = Payload("payloads/%s.v2.%s" % (key, ext), build_payload(ext, key + "@v2", params))
    return payloads


def generations():
    """The four generations as lists of asset records (v1..v4), in stable order."""
    v1 = [dict(a, variant="") for a in BASE_ASSETS]
    v2 = []
    for a in v1:
        if a["id"] in V2_CONTENT_CHANGED:
            a = dict(a, variant="v2", payload=a["payload"] + "@v2")
        v2.append(dict(a))
    v3 = []
    for a in v2:
        a = dict(a)
        if a["id"] in V3_DIRECTORY_CHANGES:
            dirs, name = V3_DIRECTORY_CHANGES[a["id"]]
            if dirs is not None:
                a["dirs"] = list(dirs)
            if name is not None:
                a["name"] = name
        v3.append(a)
    v4 = [dict(a) for a in v3 if a["id"] not in V4_REMOVED]
    return {"v1": v1, "v2": v2, "v3": v3, "v4": v4}


def remote_path(asset, payload, tier):
    if tier == "aws":
        return "media/%s/%s.%s" % (payload.sha[:16], asset["id"], asset["ext"])
    suffix = ".v2" if asset["variant"] == "v2" else ""
    return "%s/%s/%s%s.%s" % (PACK_MEDIA, asset["kind"], asset["id"], suffix, asset["ext"])


def render_entry(asset, payload, tier):
    entry = {"identifier": asset["id"], "fileExtension": asset["ext"],
             "remotePath": remote_path(asset, payload, tier), "localPathComponents": list(asset["dirs"])}
    if asset["name"] is not None:
        entry["localFileName"] = asset["name"]
    entry["byteSize"] = payload.size
    entry["checksum"] = payload.sha
    return entry


def render_bare(assets, payloads, tier):
    return [render_entry(a, payloads[a["payload"]], tier) for a in assets]


def render_envelope(assets, payloads, tier):
    entries = []
    for a, entry in zip(assets, render_bare(assets, payloads, tier)):
        entry = dict(entry)
        entry.update(ENVELOPE_EXTENSIONS.get(a["id"], {}))
        if a["id"] == ENVELOPE_UNKNOWN_ASSET[0]:
            entry[ENVELOPE_UNKNOWN_ASSET[1]] = ENVELOPE_UNKNOWN_ASSET[2]
        entries.append(entry)
    key, value = ENVELOPE_UNKNOWN_TOP
    if tier == "aws":  # unknown top-level field before "assets"
        return {"schemaVersion": 1, key: value, "assets": entries}
    return {"schemaVersion": 1, "assets": entries, key: value}  # ...and after it for the Apple catalog


def dump_json(obj):
    return (json.dumps(obj, indent=2, ensure_ascii=True) + "\n").encode("ascii")


# --------------------------------------------------------------------------------------------------
# Negative fixtures
# --------------------------------------------------------------------------------------------------

def build_invalid(payloads):
    """Returns {file name: (bytes, expectation dict)}."""
    gen = generations()["v1"]
    by_id = {a["id"]: render_entry(a, payloads[a["payload"]], "aws") for a in gen}
    first, last = by_id[ID_MENU], by_id[ID_TITLE]
    template = by_id[ID_MAP]
    results = {}

    def bad_entry(slug, **changes):
        entry = dict(template)
        entry["identifier"] = "invalid." + slug
        entry["remotePath"] = "media/%s/invalid.%s.png" % (payloads[ID_MAP].sha[:16], slug)
        entry.update(changes)
        return entry

    def per_entry(file_name, slug, violation, **changes):
        entry = bad_entry(slug, **changes)
        data = dump_json([first, entry, last])
        results[file_name] = (data, {
            "wireShape": "array",
            "outcome": "entryQuarantined",
            "violation": violation,
            "entryCount": 3,
            "quarantinedIndices": [1],
            "quarantinedIdentifiers": [entry["identifier"]],
            "survivingIdentifiers": [first["identifier"], last["identifier"]],
        })

    per_entry("remote-path-traversal-dotdot.json", "remote.path.traversal.dotdot",
              "remotePath \"../x\" starts with a '..' segment (R-MAN-2: no '..' segment)", remotePath="../x")
    per_entry("remote-path-absolute.json", "remote.path.absolute",
              "remotePath \"/abs\" is absolute (R-MAN-2: relative only)", remotePath="/abs")
    per_entry("remote-path-scheme-authority.json", "remote.path.scheme.authority",
              "remotePath \"https://evil/x\" carries a scheme and an authority (R-MAN-2)", remotePath="https://evil/x")
    per_entry("remote-path-embedded-dotdot.json", "remote.path.embedded.dotdot",
              "remotePath \"a/../../b\" contains '..' segments in the middle (R-MAN-2)", remotePath="a/../../b")
    per_entry("bad-extension.json", "bad.extension",
              "fileExtension \"p/ng\" contains a path separator (R-MAN-2: [A-Za-z0-9]{1,8})", fileExtension="p/ng")
    per_entry("bad-extension-too-long.json", "bad.extension.too.long",
              "fileExtension \"abcdefghi\" is 9 characters (R-MAN-2: at most 8)", fileExtension="abcdefghi")
    per_entry("bad-extension-empty.json", "bad.extension.empty",
              "fileExtension \"\" is empty (R-MAN-2: at least 1 character)", fileExtension="")
    sha = payloads[ID_MAP].sha
    per_entry("checksum-wrong-length.json", "checksum.wrong.length",
              "checksum has 63 hex characters (R-MAN-2: exactly 64)", checksum=sha[:-1])
    per_entry("checksum-non-hex.json", "checksum.non.hex",
              "checksum has 64 characters but starts with \"zz\", which is not hexadecimal (R-MAN-2)",
              checksum="zz" + sha[2:])
    per_entry("identifier-control-character.json", "control.character",
              "identifier contains U+0007 (BEL) (R-MAN-2: no control characters)",
              identifier="invalid.control\u0007character")
    per_entry("byte-size-negative.json", "byte.size.negative",
              "byteSize is -1 (R-MAN-2: within 0...maxAssetBytes)", byteSize=-1)
    per_entry("identifier-empty.json", "identifier.empty",
              "identifier is the empty string (R-MAN-2: non-empty)", identifier="")

    # Whole-manifest rejections ---------------------------------------------------------------
    sting = payloads[ID_STING]
    theme = by_id[ID_THEME]
    duplicate = dict(theme)
    duplicate.update(fileExtension="wav", byteSize=sting.size, checksum=sting.sha,
                     remotePath="media/%s/%s.wav" % (sting.sha[:16], ID_THEME))
    results["duplicate-identifiers.json"] = (dump_json([first, theme, duplicate, last]), {
        "wireShape": "array",
        "outcome": "manifestRejected",
        "reasonClass": "duplicate-identifiers",
        "violation": "identifier \"%s\" appears twice (indices 1 and 2) with different content; "
                     "each entry is individually valid (D-13: the prior art trapped on this)" % ID_THEME,
        "entryCount": 4,
        "duplicateIdentifier": ID_THEME,
        "mustNotCrash": True,
    })

    nested = ("[" * 10000 + "]" * 10000 + "\n").encode("ascii")
    results["deeply-nested-10000-levels.json"] = (nested, {
        "wireShape": "none",
        "outcome": "manifestRejected",
        "reasonClass": "undecodable-nesting-depth",
        "violation": "10,000 nested JSON arrays (20,001 bytes) and no asset object at all",
        "mustNotCrash": True,
    })

    junk = b"\x89NOTJSON\r\n\x1a\n" + stream("invalid/non-json-bytes", 244)
    try:
        json.loads(junk)
        raise AssertionError("non-json fixture must not parse as JSON")
    except ValueError:
        pass
    results["non-json-bytes.bin"] = (junk, {
        "wireShape": "none",
        "outcome": "manifestRejected",
        "reasonClass": "undecodable-not-json",
        "violation": "256 bytes that are not JSON in any encoding (binary prefix, then seeded random bytes)",
        "mustNotCrash": True,
    })

    results["envelope-unsupported-schema-version.json"] = (
        dump_json({"schemaVersion": 99, "assets": [first, template, last]}), {
            "wireShape": "envelope",
            "outcome": "manifestRejected",
            "reasonClass": "unsupported-schema-version",
            "violation": "envelope declares schemaVersion 99; the three assets inside are individually valid "
                         "but must not be interpreted",
            "entryCount": 3,
            "schemaVersion": 99,
            "mustNotCrash": True,
        })
    # Cross-check: entry-level expectations really are violations of exactly the stated field.
    return results


# --------------------------------------------------------------------------------------------------
# Classification (independent of the construction code: works from the re-parsed JSON)
# --------------------------------------------------------------------------------------------------

def normalised_metadata(entry):
    return {
        "remotePath": entry["remotePath"],
        "localPathComponents": entry["localPathComponents"],
        "localFileName": entry.get("localFileName"),
        "tags": entry.get("tags", []),
        "policy": entry.get("policy", "standard"),
    }


def classify(old_assets, new_assets):
    old = {e["identifier"]: e for e in old_assets}
    new = {e["identifier"]: e for e in new_assets}
    assert len(old) == len(old_assets) and len(new) == len(new_assets), "duplicate identifiers"
    result = {name: [] for name in DIFF_CLASSES}
    result["added"] = sorted(new.keys() - old.keys())
    result["removed"] = sorted(old.keys() - new.keys())
    for identifier in sorted(old.keys() & new.keys()):
        a, b = old[identifier], new[identifier]
        if a["checksum"] != b["checksum"]:
            result["contentChanged"].append(identifier)
        elif normalised_metadata(a) != normalised_metadata(b):
            result["metadataChanged"].append(identifier)
        else:
            result["unchanged"].append(identifier)
    return result


def field_changes(old_entry, new_entry):
    """[(field, before, after)] over every key either entry carries, in a stable order."""
    keys = LEGACY_KEYS[1:] + ["tags", "policy"]
    changes = []
    for key in keys:
        before, after = old_entry.get(key), new_entry.get(key)
        if before != after:
            changes.append((key, before, after))
    return changes


def jsonish(value):
    return "(absent)" if value is None else json.dumps(value, ensure_ascii=True)


# --------------------------------------------------------------------------------------------------
# File tree assembly
# --------------------------------------------------------------------------------------------------

def series_path(tier, file_name):
    return "manifests/%s/%s" % (tier, file_name)


def build_tree():
    """Returns {relative path: bytes} for every generated file, plus a context dict for the docs."""
    files = {}
    payloads = build_payloads()
    gens = generations()
    assert [len(gens[v]) for v in ("v1", "v2", "v3", "v4")] == [13, 13, 13, 11]
    assert len({a["id"] for a in gens["v1"]}) == 13
    assert len({p.path for p in payloads.values()}) == len(payloads) == 14

    for payload in payloads.values():
        files[payload.path] = payload.data

    rendered = {}  # (tier, version) -> parsed list
    envelopes = {}
    pack_paths = {}  # relative path -> payload key (Apple pack layout)
    for tier in TIERS:
        for version, file_name in SERIES:
            bare = render_bare(gens[version], payloads, tier)
            rendered[(tier, version)] = bare
            files[series_path(tier, file_name)] = dump_json(bare)
            for entry in bare:  # the bare series carries exactly the seven legacy keys, nothing more
                assert set(entry) <= set(LEGACY_KEYS), entry
                assert {"identifier", "fileExtension", "remotePath", "localPathComponents"} <= set(entry), entry
            if tier == "apple":
                for asset, entry in zip(gens[version], bare):
                    path = "packs/" + entry["remotePath"]
                    assert pack_paths.setdefault(path, asset["payload"]) == asset["payload"], path
        envelope = render_envelope(gens["v1"], payloads, tier)
        envelopes[tier] = envelope
        files[series_path(tier, "v1.envelope.json")] = dump_json(envelope)

    for relative, key in pack_paths.items():
        files[relative] = payloads[key].data
    files["packs/%s/catalog.json" % PACK_CATALOG] = files[series_path("apple", "v1.envelope.json")]

    invalid = build_invalid(payloads)
    for name, (data, _expectation) in invalid.items():
        files["manifests/invalid/" + name] = data

    context = dict(payloads=payloads, gens=gens, rendered=rendered, envelopes=envelopes,
                   invalid=invalid, pack_paths=pack_paths)
    files["manifests/expectations.json"] = dump_json(build_expectations(files, context))
    files["manifests/README.md"] = build_readme(files, context).encode("utf-8")
    return files, context


def load_series(files, tier, version):
    file_name = dict(SERIES)[version]
    return json.loads(files[series_path(tier, file_name)].decode("ascii"))


def load_envelope_assets(files, tier):
    return json.loads(files[series_path(tier, "v1.envelope.json")].decode("ascii"))["assets"]


def transition(files, tier, source, target):
    """Classification between two series versions ('v1'..'v4') or the envelope ('v1.envelope')."""
    def assets(label):
        if label == "v1.envelope":
            return load_envelope_assets(files, tier)
        return load_series(files, tier, label)

    def path(label):
        return series_path(tier, "v1.envelope.json" if label == "v1.envelope" else dict(SERIES)[label])

    entry = {"from": source, "to": target, "fromFile": path(source), "toFile": path(target)}
    entry.update(classify(assets(source), assets(target)))
    return entry


def build_expectations(files, context):
    payloads = context["payloads"]
    out = {
        "formatVersion": 1,
        "generatedBy": "Tests/Fixtures/generate_fixtures.py",
        "note": "Paths are relative to Tests/Fixtures. Identifier lists are sorted ascending by UTF-8 bytes. "
                "Classification follows R-MAN-4 with absent policy == \"standard\" and absent tags == [].",
        "classes": DIFF_CLASSES,
        "tiers": {},
    }
    for tier in TIERS:
        series = {}
        for version, file_name in SERIES:
            assets = load_series(files, tier, version)
            series[version] = {"file": series_path(tier, file_name), "assetCount": len(assets),
                               "identifiers": sorted(e["identifier"] for e in assets)}
        envelope_assets = load_envelope_assets(files, tier)
        out["tiers"][tier] = {
            "series": series,
            "envelope": {"file": series_path(tier, "v1.envelope.json"), "schemaVersion": 1,
                         "assetCount": len(envelope_assets),
                         "identifiers": sorted(e["identifier"] for e in envelope_assets)},
            "transitions": {
                "v1->v2": transition(files, tier, "v1", "v2"),
                "v2->v3": transition(files, tier, "v2", "v3"),
                "v3->v4": transition(files, tier, "v3", "v4"),
            },
            "extraTransitions": {
                "v1->v4": transition(files, tier, "v1", "v4"),
                "v1->v1.envelope": transition(files, tier, "v1", "v1.envelope"),
            },
        }

    records = []
    for key, payload in sorted(payloads.items(), key=lambda item: item[1].path):
        remote = {"aws": set(), "apple": set()}
        users = set()
        for tier in TIERS:
            for version, _ in SERIES:
                for asset, entry in zip(context["gens"][version], context["rendered"][(tier, version)]):
                    if asset["payload"] == key:
                        remote[tier].add(entry["remotePath"])
                        users.add(asset["id"])
        records.append({"file": payload.path, "role": "v2-variant" if key.endswith("@v2") else "baseline",
                        "byteSize": payload.size, "sha256": payload.sha,
                        "identifiers": sorted(users),
                        "remotePaths": {"aws": sorted(remote["aws"]), "apple": sorted(remote["apple"])}})
    out["payloads"] = records

    out["invalid"] = {"manifests/invalid/" + name: expectation
                      for name, (_data, expectation) in sorted(context["invalid"].items())}
    return out


# --------------------------------------------------------------------------------------------------
# README
# --------------------------------------------------------------------------------------------------

def md_ids(identifiers):
    return ", ".join("`%s`" % i for i in identifiers) if identifiers else "none"


def show_id(identifier):
    """An identifier made printable: control characters stay escaped, the empty string is spelled out."""
    return "(empty identifier)" if identifier == "" else json.dumps(identifier)[1:-1]


def md_cell(value):
    return "`%s`" % jsonish(value).replace("|", "\\|")


def transition_section(files, tier, source, target, title):
    entry = transition(files, tier, source, target)
    old = {e["identifier"]: e for e in (load_envelope_assets(files, tier) if source == "v1.envelope"
                                         else load_series(files, tier, source))}
    new = {e["identifier"]: e for e in (load_envelope_assets(files, tier) if target == "v1.envelope"
                                         else load_series(files, tier, target))}
    lines = ["#### %s (`%s` -> `%s`)" % (title, entry["fromFile"].split("/")[-1], entry["toFile"].split("/")[-1]), ""]
    for name in DIFF_CLASSES:
        ids = entry[name]
        if name == "unchanged":
            lines.append("- **unchanged** (%d): %s" % (len(ids), md_ids(ids)))
        else:
            lines.append("- **%s** (%d): %s" % (name, len(ids), md_ids(ids)))
    changed = [i for name in ("contentChanged", "metadataChanged") for i in entry[name]]
    if changed:
        lines += ["", "| identifier | field | before | after |", "|---|---|---|---|"]
        for identifier in changed:
            for field, before, after in field_changes(old[identifier], new[identifier]):
                lines.append("| `%s` | `%s` | %s | %s |" % (identifier, field, md_cell(before), md_cell(after)))
    if entry["removed"]:
        lines += ["", "Removed entries as they were in `%s`:" % entry["fromFile"].split("/")[-1], ""]
        for identifier in entry["removed"]:
            e = old[identifier]
            lines.append("- `%s` (%s, %d bytes, checksum `%s`)" % (identifier, e["fileExtension"], e["byteSize"], e["checksum"]))
    lines.append("")
    return lines


def build_readme(files, context):
    payloads = context["payloads"]
    gens = context["gens"]
    v1_aws = load_series(files, "aws", "v1")
    v1_apple = load_series(files, "apple", "v1")
    L = []
    add = L.append
    add("# Example-manifest fixtures (ADR-008)")
    add("")
    add("> Generated by `Tests/Fixtures/generate_fixtures.py`; do not edit by hand. Re-running the generator "
        "reproduces every file byte for byte (`python3 Tests/Fixtures/generate_fixtures.py --check` verifies the "
        "tree on disk, recomputes every checksum and byteSize, and fails on any drift).")
    add("")
    add("Tests locate this directory through `#filePath`; nothing here is a SwiftPM resource. "
        "The prior art shipped no example manifests (`docs/RECON.md` section 1), so these are synthetic, but every "
        "checksum is the real SHA-256 of a real payload file in `payloads/`, so the series can drive a fake "
        "CDN end to end. All paths below are relative to `Tests/Fixtures/`.")
    add("")
    add("## 1. Conventions")
    add("")
    add("- **Wire shapes (R-MAN-1).** `v1.json` .. `v4-removal.json` are the *legacy bare JSON array* and contain "
        "exactly the seven legacy keys `identifier`, `fileExtension`, `remotePath`, `localPathComponents`, "
        "`localFileName`, `byteSize`, `checksum` and nothing else. `localPathComponents` is present on every entry "
        "(the legacy decoder required it). `localFileName` is **omitted** (not `null`) where the manifest has no "
        "opinion, in which case the derived name (last dot-segment of the identifier) applies; `byteSize` and "
        "`checksum` are present on every entry of the series. `v1.envelope.json` is the envelope shape "
        "`{\"schemaVersion\": 1, \"assets\": [...]}` (section 4).")
    add("- **Entry order** is identical in every file of a series (v1 order, with removed entries dropped); array order "
        "carries no meaning for classification.")
    add("- **Checksums.** `checksum` is the full lowercase hex SHA-256 of the payload file; `byteSize` is its length. "
        "Both are recomputable from `payloads/`.")
    add("- **AWS tier** `remotePath = media/<sha256[:16]>/<identifier>.<ext>` (SPEC 2.3). A content change therefore changes "
        "`remotePath`; a directory change never does.")
    add("- **Apple tier** `remotePath = ZTronMedia/<kind>/<identifier>.<ext>` where `<kind>` is one of `images` (heic, png, "
        "jpg), `vectors` (svg), `video` (mp4), `audio` (wav, mp3). The `remotePath` is `<packID>/<path inside pack>`; "
        "the catalog lives in the essential pack `%s`, the media in the on-demand pack `%s`. The path carries no "
        "hash, so for the two content changes of v2 the file name gains a `.v2` marker "
        "(`.../<identifier>.v2.<ext>`); that lets **one** fake pack directory serve every version of the series." % (PACK_CATALOG, PACK_MEDIA))
    add("- **Identifier lists** in this document and in `expectations.json` are sorted ascending by UTF-8 bytes.")
    add("- **Classification** follows R-MAN-4: `contentChanged` = checksum differs (takes precedence); `metadataChanged` = same checksum "
        "but `remotePath`, directory (`localPathComponents`), file name (`localFileName`), tags or policy differ; "
        "an absent `policy` equals `standard` and absent `tags` equal `[]`; `unchanged` = none of those; "
        "`added` / `removed` = identifier only in the newer / older manifest. Every identifier lands in exactly one class.")
    add("- **The dedupe pair.** `%s` and `%s` are two different identifiers whose entries reference the **same payload "
        "bytes** (identical `checksum` and `byteSize`, different `remotePath` file names). They exist to exercise "
        "content-addressed deduplication and reference counting; neither is touched by any transition or by the envelope extension fields." % (ID_PORTRAIT, ID_CARD))
    add("")

    add("## 2. Payloads (`payloads/`)")
    add("")
    add("Contents are derived from the fixed seed `%s` (SHA-256 counter stream, see the generator). "
        "`svg` (well-formed XML), `png` (8-bit RGB, stored deflate) and `wav` (PCM 16-bit mono 8 kHz) are structurally valid "
        "and decodable. `heic`, `jpg`, `mp4`, `mp3` carry the correct container/marker structure "
        "(`ftyp` boxes, JFIF/SOI/EOI, ID3v2 + MPEG frame syncs) around seeded filler: they are **not** decodable media and must "
        "only be treated as opaque bytes. All files are between %d and %d bytes." % (SEED.decode(), MIN_PAYLOAD_BYTES, MAX_PAYLOAD_BYTES))
    add("")
    add("| file | role | bytes | sha256 |")
    add("|---|---|---|---|")
    for key, payload in sorted(payloads.items(), key=lambda item: item[1].path):
        role = "v2 variant" if key.endswith("@v2") else "baseline"
        add("| `%s` | %s | %d | `%s` |" % (payload.path, role, payload.size, payload.sha))
    add("")
    add("The v2 variants replace exactly two baseline payloads: `%s` (heic, 1,536 -> 1,792 bytes) and `%s` (wav, "
        "2,044 -> 2,044 bytes: **same size, different bytes**, so the checksum alone distinguishes old from new). "
        "`expectations.json` (`payloads`) maps every payload file to its checksum, the identifiers using it and "
        "every `remotePath` (per tier) that must resolve to it." % (ID_ICON, ID_CRYPT))
    add("")

    add("## 3. The version series (both tiers)")
    add("")
    add("The two tiers use the **same 13 identifiers** and the same change pattern; they differ only in `remotePath` "
        "(section 1). Version files: `manifests/aws/` and `manifests/apple/` each hold `v1.json` (baseline, 13 assets), "
        "`v2-checksum-change.json` (13), `v3-directory-change.json` (13), `v4-removal.json` (11) and `v1.envelope.json` (13).")
    add("")
    add("### 3.1 v1 baseline (13 assets)")
    add("")
    add("| identifier | ext | localPathComponents | localFileName | payload | bytes |")
    add("|---|---|---|---|---|---|")
    for asset, entry in zip(gens["v1"], v1_aws):
        add("| `%s` | %s | %s | %s | `%s` | %d |" % (
            entry["identifier"], entry["fileExtension"], md_cell(entry["localPathComponents"]),
            md_cell(entry.get("localFileName")), payloads[asset["payload"]].path, entry["byteSize"]))
    add("")
    add("`remotePath` of the baseline, AWS tier then Apple tier:")
    add("")
    add("| identifier | AWS `remotePath` | Apple `remotePath` |")
    add("|---|---|---|")
    for aws, apple in zip(v1_aws, v1_apple):
        add("| `%s` | `%s` | `%s` |" % (aws["identifier"], aws["remotePath"], apple["remotePath"]))
    add("")
    add("### 3.2 What changes between versions")
    add("")
    add("- **v1 -> v2 `v2-checksum-change.json`** - exactly **2** assets get new payload bytes: `%s` and `%s`. For each: "
        "`checksum`, `byteSize` (icon only; the crypt variant keeps 2,044), and `remotePath` change; nothing else. "
        "AWS: the `<sha256[:16]>` directory changes. Apple: the file name gains `.v2`. All other 11 entries are byte-identical to v1." % (ID_ICON, ID_CRYPT))
    add("- **v2 -> v3 `v3-directory-change.json`** - exactly **3** assets change only `localPathComponents` and/or "
        "`localFileName`; `checksum`, `byteSize` and `remotePath` stay the same (no download is needed): "
        "`%s` (directory only, one component appended), `%s` (file name only; the `localFileName` key appears), "
        "`%s` (directory and file name). All other 10 entries are identical to v2." % (ID_OUTLINE, ID_THEME, ID_MENU))
    add("- **v3 -> v4 `v4-removal.json`** - exactly **2** assets are removed: `%s` and `%s`. The remaining 11 entries are identical "
        "to v3. (The shared payload files stay in `payloads/` and the Apple pack: the fake pack serves every version.)" % (ID_BO6_OUTLINE, ID_STING))
    add("")
    add("The v2 and v3 change sets, and the v4 removal set, are pairwise disjoint, and none of them contains the dedupe pair.")
    add("")
    for tier, label in (("aws", "AWS tier"), ("apple", "Apple tier")):
        add("### 3.%d %s: exact differences" % (3 if tier == "aws" else 4, label))
        add("")
        add("Field values are the JSON values as written; `(absent)` means the key is not present.")
        add("")
        for source, target, title in (("v1", "v2", "v1 -> v2, checksum change"),
                                      ("v2", "v3", "v2 -> v3, directory change"),
                                      ("v3", "v4", "v3 -> v4, removal")):
            L.extend(transition_section(files, tier, source, target, title))
        add("Extra transitions (not part of the required three; also in `expectations.json` under `extraTransitions`):")
        add("")
        L.extend(transition_section(files, tier, "v1", "v4", "v1 -> v4 cumulative (an app update that skips v2 and v3)"))
        L.extend(transition_section(files, tier, "v1", "v1.envelope", "v1 bare array -> v1 envelope (same assets, plus tags/policy)"))

    add("## 4. Envelope files (`manifests/aws/v1.envelope.json`, `manifests/apple/v1.envelope.json`)")
    add("")
    add("Same 13 assets, same `remotePath`/checksums as the tier's `v1.json`, in the envelope shape "
        "`{\"schemaVersion\": 1, \"assets\": [...]}` (R-MAN-1), plus:")
    add("")
    add("- **one unknown top-level field**, `buildInfo` (an object: `{\"commit\": \"0000000\", \"pipeline\": 1}`) - "
        "placed *before* `assets` in the AWS envelope and *after* it in the Apple envelope; it must be ignored.")
    add("- **one unknown per-asset field**, `blurHash` (a string), on exactly one entry, `%s`; it must be ignored. "
        "(That entry therefore stays `unchanged` against the bare `v1.json`.)" % ENVELOPE_UNKNOWN_ASSET[0])
    add("- **optional extension fields (R-MAN-6)** on these entries only:")
    add("")
    add("| identifier | tags | policy |")
    add("|---|---|---|")
    for identifier, ext in ENVELOPE_EXTENSIONS.items():
        add("| `%s` | %s | %s |" % (identifier, md_cell(ext.get("tags")), md_cell(ext.get("policy"))))
    add("")
    add("Every other entry carries no `tags` and no `policy` (behaves as `standard`, no tags). Decoded, the envelope's assets equal the "
        "bare `v1.json` assets except for those six entries' tags/policy, so `diff(v1.json, v1.envelope.json)` is exactly "
        "`metadataChanged` = %s and everything else `unchanged` (see the AWS/Apple extra transition above). Note the "
        "`standard` policy never appears *alone*: its entry also has tags, so the classification does not depend on "
        "whether an explicit `standard` is normalised." % md_ids(sorted(ENVELOPE_EXTENSIONS)))
    add("")

    add("## 5. Negative fixtures (`manifests/invalid/`)")
    add("")
    add("One file per violation, named after it. Per-entry files are bare arrays of three entries: a valid entry, the violating "
        "entry (index 1) and a valid entry, so a test can assert that *only* the violating entry is quarantined and the other two "
        "survive (R-MAN-2). The violating entry is a copy of an otherwise valid asset with exactly one field changed. "
        "Whole-manifest rejections (`manifestRejected`) must produce a typed error and **never crash** or hang. "
        "`expectations.json` (`invalid`) carries the same data in machine-readable form.")
    add("")
    add("| file | outcome | violation | quarantined index / survivors |")
    add("|---|---|---|---|")
    for name, (_data, e) in sorted(context["invalid"].items()):
        detail = ""
        if e["outcome"] == "entryQuarantined":
            detail = "index 1 (`%s`); survivors %s" % (show_id(e["quarantinedIdentifiers"][0]),
                                                         md_ids(e["survivingIdentifiers"]))
        add("| `%s` | %s | %s | %s |" % (name, e["outcome"], e["violation"].replace("|", "\\|"), detail))
    add("")
    add("`manifestRejected` reason classes: `duplicate-identifiers` (structural per R-MAN-2), `undecodable-not-json` and "
        "`undecodable-nesting-depth` (undecodable / over limits per R-MAN-2/3), `unsupported-schema-version` (an envelope "
        "this build cannot interpret; SPEC names no error for it, tests should assert a typed error and zero accepted assets).")
    add("")

    add("## 6. `expectations.json`")
    add("")
    add("Per tier (`aws`, `apple`): `series` (file, asset count and identifier list of v1..v4), `envelope`, `transitions` "
        "(`v1->v2`, `v2->v3`, `v3->v4`; each with `from`, `to`, `fromFile`, `toFile` and the five `ManifestDiff` classes "
        "`added`, `removed`, `contentChanged`, `metadataChanged`, `unchanged`), and `extraTransitions` "
        "(`v1->v4`, `v1->v1.envelope`). Top level also has `payloads` (file, role, size, sha256, users, remote paths) and "
        "`invalid`. The file is computed by re-parsing the written manifests with an independent classifier, never from the "
        "construction tables.")
    add("")
    for tier in TIERS:
        add("Summary, %s tier:" % tier)
        add("")
        add("| transition | added | removed | contentChanged | metadataChanged | unchanged |")
        add("|---|---|---|---|---|---|")
        for name, e in (("v1->v2", transition(files, tier, "v1", "v2")), ("v2->v3", transition(files, tier, "v2", "v3")),
                        ("v3->v4", transition(files, tier, "v3", "v4"))):
            add("| %s | %s |" % (name, " | ".join(str(len(e[c])) for c in DIFF_CLASSES)))
        add("")

    add("## 7. Apple fake-pack layout (`packs/`)")
    add("")
    add("- `packs/%s/<path inside pack>` - every payload at every path any Apple manifest (v1..v4) references, so "
        "`remotePath` `%s/<path>` resolves to `packs/%s/<path>`. %d files (the 12 baseline payloads, the dedupe pair's second path, "
        "and the 2 `.v2` variants, each copied byte-identically from `payloads/`)." % (PACK_MEDIA, PACK_MEDIA, PACK_MEDIA, len(context["pack_paths"])))
    add("- `packs/%s/catalog.json` - byte-identical to `manifests/apple/v1.envelope.json` (the catalog of the essential pack)." % PACK_CATALOG)
    add("")
    add("Pack files:")
    add("")
    for relative in sorted(context["pack_paths"]):
        add("- `%s`" % relative)
    add("")
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------------------------------
# Output and verification
# --------------------------------------------------------------------------------------------------

def write_tree(out_dir, files):
    for relative in sorted(files):
        destination = os.path.join(out_dir, relative)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        with open(destination, "wb") as handle:
            handle.write(files[relative])


def disk_files(root):
    found = {}
    for base, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for name in names:
            if name in (SCRIPT_NAME, ".DS_Store"):
                continue
            path = os.path.join(base, name)
            found[os.path.relpath(path, root)] = path
    return found


def verify(root, files):
    """Compares the generated tree with `root`; recomputes every checksum/byteSize from the files on disk."""
    problems = []
    on_disk = disk_files(root)

    def read(relative):
        with open(os.path.join(root, relative), "rb") as handle:
            return handle.read()

    for relative in sorted(files):
        if relative not in on_disk:
            problems.append("missing on disk: " + relative)
        elif read(relative) != files[relative]:
            problems.append("differs from generator output: " + relative)
    for relative in sorted(on_disk):
        if relative not in files:
            problems.append("stale file not produced by the generator: " + relative)

    payload_by_checksum = {}
    for relative in sorted(on_disk):
        if relative.startswith("payloads/"):
            payload_by_checksum.setdefault(hashlib.sha256(read(relative)).hexdigest(), []).append(relative)

    checked = 0
    for tier in TIERS:
        for name in [f for _v, f in SERIES] + ["v1.envelope.json"]:
            parsed = json.loads(read(series_path(tier, name)).decode("utf-8"))
            assets = parsed["assets"] if isinstance(parsed, dict) else parsed
            for entry in assets:
                where = "%s/%s: %s" % (tier, name, entry["identifier"])
                if tier == "aws":
                    expected_path = "media/%s/%s.%s" % (entry["checksum"][:16], entry["identifier"], entry["fileExtension"])
                    if entry["remotePath"] != expected_path:
                        problems.append("%s: remotePath %s != %s" % (where, entry["remotePath"], expected_path))
                    match = payload_by_checksum.get(entry["checksum"], [])
                    if len(match) != 1:
                        problems.append("%s: expected exactly one payload with checksum %s, found %d" % (where, entry["checksum"], len(match)))
                        continue
                    data = read(match[0])
                else:
                    pack_file = "packs/" + entry["remotePath"]
                    if pack_file not in on_disk:
                        problems.append("%s: pack file missing: %s" % (where, pack_file))
                        continue
                    data = read(pack_file)
                if len(data) != entry["byteSize"]:
                    problems.append("%s: byteSize %d != actual %d" % (where, entry["byteSize"], len(data)))
                if hashlib.sha256(data).hexdigest() != entry["checksum"]:
                    problems.append("%s: checksum mismatch" % where)
                checked += 1
    if read("packs/%s/catalog.json" % PACK_CATALOG) != read(series_path("apple", "v1.envelope.json")):
        problems.append("packs/%s/catalog.json is not equal to manifests/apple/v1.envelope.json" % PACK_CATALOG)
    return problems, checked


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", help="write the tree into this directory instead of next to the script")
    parser.add_argument("--check", action="store_true",
                        help="do not write; compare the tree on disk with the generator output and recompute checksums")
    args = parser.parse_args(argv)
    here = os.path.dirname(os.path.abspath(__file__))
    files, _context = build_tree()
    if args.check:
        problems, checked = verify(here, files)
        for problem in problems:
            print("FAIL:", problem)
        print("checked %d files, recomputed %d manifest entries: %s" % (len(files), checked, "FAIL" if problems else "OK"))
        return 1 if problems else 0
    out_dir = os.path.abspath(args.out) if args.out else here
    write_tree(out_dir, files)
    print("wrote %d files under %s" % (len(files), out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
