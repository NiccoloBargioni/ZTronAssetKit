# Stage 0 recon — the prior art

Read-only inspection of `../ZTronCarouselCore` (branch `main` @ `b4a5f4c`, clean working tree) and
`../ZTronCarousel` (`main` @ `f8c7ccb`, clean) on 2026-10-04. Neither repository was modified. Paths below
are relative to `ZTronCarouselCore/Sources/ZTronCarouselCore/` unless stated otherwise.

## 1. The prior art differs from SPEC §2.1

| SPEC says | Found on disk |
|---|---|
| 11 files in `CDN/` | **9** files. `AWSCloudFrontCDNProvider.swift` and `CDNProviderFactory.swift` do not exist on any local or remote branch (`git ls-tree` over all 9 refs). |
| 128 CDN-related tests in `Tests/ZTronCarouselCoreTests` | **0**. The only test file is the template `ZTronCarouselCoreTests.swift` with one assertion-free `example()` test. No branch has more. |
| Example manifests in `Manifests/`, plus `DESIGN.md` / `VALIDATION.md` | None of these exist in either repository. |
| `BasicImagePage`: bundle → local cache → network | `ImagePage/BasicImagePage.swift:62-74` is **bundle-only** (asset catalog, then `heic, png, jpg, jpeg` in the bundle) and `fatalError`s on a miss (`:27-29`). The 3-step chain exists only in `ZTronSVGView` (ZTronCarousel `Components/Internals/ZTronSVGView.swift:117-160`); `BasicVideoPage` has bundle → local only (`VideoPage/BasicVideoPage.swift:56-58`). |

Consequences (recorded in `DECISIONS.md`): the remote-side facts of §2.3 (CloudFront, app-key header, content-addressed keys)
are taken from the SPEC as authoritative because no code for them exists; example manifests are authored
as synthetic fixtures; the characterization baseline is the prior art's *behaviour as read*, re-expressed
as tests in this package.

## 2. Defects D-1…D-12

| ID | Verdict | Evidence |
|---|---|---|
| D-1 | **Confirmed** | `CDN/StaticManifestCDNProvider.swift:60` — `URLSession(configuration: .default, delegate:…)` created inside `download(from:)`, once per download. |
| D-2 | **Confirmed** | `CDN/CDNSyncCoordinator.swift:138-179` — serial `for asset in manifest` with `try await self.cdn.downloadAsset` (`:151`) and `try self.localStore.store` (`:171`); the first throw aborts the whole sync (`:89-91`). |
| D-3 | **Confirmed** | `StaticManifestCDNProvider.swift:60` — `.default` configuration only; no background session anywhere. |
| D-4 | **Confirmed** | No resume data, `Range`, size cap, free-space check, quota or eviction anywhere in `CDN/` (grep for `resumeData`, `Range`, `volumeAvailableCapacity`, `byteSize` use: `byteSize` is never read). |
| D-5 | **Confirmed (7)** | `@unchecked Sendable`: `CDNLocalStore.swift:15`, `NetworkAvailabilityMonitor.swift:14`, `StaticManifestCDNProvider.swift:77`. `nonisolated(unsafe)`: `CDNAssetResolver.swift:19`, `CDNLocalStore.swift:23`, `:29`, `NetworkAvailabilityMonitor.swift:21`. |
| D-6 | **Confirmed** | Stamp in `UserDefaults` (`CDNSyncCoordinator.swift:31`, `:68`, `:87`); files in `Library/Caches/CDNAssets` (`CDNLocalStore.swift:52-54`). |
| D-7 | **Confirmed** | `StaticManifestCDNProvider.swift:117-120` moves the download into `FileManager.default.temporaryDirectory`; `BackgroundAssetsCDNProvider.swift:81-82` writes to `tmp`. Nothing ever cleans `tmp`. |
| D-8 | **Confirmed** | `CDNSyncCoordinator.swift:151-168` — a `Task { @MainActor }` per progress callback. |
| D-9 | **Confirmed** | `StaticManifestCDNProvider.swift:35` — `JSONDecoder().decode([CDNAsset].self, from: data)` with no size, count or field validation. |
| D-10 | **Confirmed** | `CDNLocalStore.swift:287-317` — a directory change is `createDirectory` + `removeItem` + `moveItem` per file, not atomic as a set. |
| D-11 | **Confirmed** | `BackgroundAssetsCDNProvider.swift:76-82` — `contents(at:searchingInAssetPackWithID:)` into `Data`, then written to a new file. |
| D-12 | **Not present in code** | Nothing references `DownloadStatusUpdate`; the inference lives only in the SPEC. Resolved against the SDK in `APPLE-API-VERIFICATION.md` (R-APL-2). |

## 3. Additional defects found

| ID | Defect | Evidence | Fixed by |
|---|---|---|---|
| D-13 | A manifest with a **duplicate identifier crashes the app**: `Dictionary(uniqueKeysWithValues:)` traps on duplicate keys. | `CDNLocalStore.swift:79`, `:103`, `:280` | R-MAN-2 (duplicates reject the manifest with a typed error) |
| D-14 | **Path traversal**: manifest-supplied `localPathComponents` / `localFileName` / `identifier` segments become path components unchecked (`"..", "/"`). | `CDNLocalStore.swift:121-142`, `:165-169` | R-SEC-2, §4.3 (no manifest text in paths) |
| D-15 | **Main-thread file I/O and hashing**: `CDNSyncCoordinator` is `@MainActor` and calls `reconcile` (moves/deletes) and `store` (whole-file SHA-256 + move) on the main actor. `existingLocalURL` does `fileExists` on main from the UI. | `CDNSyncCoordinator.swift:23`, `:83`, `:171`; `CDNLocalStore.swift:68-72`, `:157-179` | R-STO-7, C2, P-8 |
| D-16 | **Downloads are never verified against the manifest checksum**; the recorded checksum is of whatever arrived. A corrupt download is stored, then `hasAsset` reports it stale forever ⇒ re-downloaded on every sync (unbounded loop). | `CDNLocalStore.swift:192-205`, `:226-232` | R-INT-2, R-INT-3, R-INT-6 |
| D-17 | Whole-file `Data(contentsOf:, .mappedIfSafe)` hashing; a read error is swallowed (`try?`) and the file is then trusted on existence alone. | `CDNLocalStore.swift:68-72`, `:226` | R-INT-1 |
| D-18 | Manifest JSON written non-atomically with respect to the files it describes (two independent `.atomic` writes, files moved in between) — a crash mid-reconcile leaves manifest and disk disagreeing. | `CDNLocalStore.swift:101-109`, `:235-255`, `:319` | R-STO-4, §4.3 |
| D-19 | `CDNAssetResolver.installed` is a mutable global read from UI code. | `CDNAssetResolver.swift:19` | §4.2 (no global mutable state) |

## 4. Ad-hoc carousel caches (R-CLN-11 inventory)

`grep -rn "NSCache\|URLCache\|imageCache\|static var .*[Cc]ache"` over both repositories' `Sources/` finds **none**.
Decoded images are owned by `UIImageView`s; SVG layers by `ZTronSVGView`. Consequence: `MemoryPressureSource`
(R-CLN-11, MAY) is provided as a protocol hook only; nothing in the carousel needs to adopt it today.

## 5. Behaviours to preserve (as read)

- Manifest wire format: a bare JSON array of objects with the seven `CDNAsset` keys (`CDNAsset.swift:8-62`); `localPathComponents` is **required** in the synthesized `Codable` (non-optional `[String]`), the other optional fields may be absent.
- `resolvedFileName` = `localFileName ?? last dot-segment of identifier` (`CDNAsset.swift:66-72`).
- Legacy on-disk path = `Caches/CDNAssets/<localPathComponents or identifier segments minus last>/<resolvedFileName>.<ext>` (`CDNLocalStore.swift:127-143`), plus `manifest.json` (`[CDNAsset]`) and `local-checksums.json` (`[identifier: lowercase-hex SHA-256]`).
- Legacy `UserDefaults` key: `ZTronCarouselCore.CDNSyncCoordinator.lastSyncedVersion`, value `"<CFBundleShortVersionString>+<CFBundleVersion>"` (`CDNSyncCoordinator.swift:31`, `:58-63`).
- Reconcile before download (`CDNSyncCoordinator.swift:76-85`); on-demand resolve never reconciles (`CDNLocalStore.swift:270-276`).
- `existingLocalURL` is offline and trusts the cached manifest (`CDNLocalStore.swift:157-179`); candidate extensions are tried in order.
- Connectivity-retry for failed on-demand fetches (`NetworkAvailabilityMonitor.swift`, used by `ZTronSVGView.swift:168-183`).
- Sync progress semantics `idle / upToDate / syncing(fraction, completed, total) / complete / failed(reason)` (`CDNSyncProgress.swift`).
