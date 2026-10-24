# Adversarial review #1 — `docs/design/transport.md` (security and HTTP semantics)
**Historical.** A Stage 1 adversarial review of a design draft, kept as written; each finding's resolution is in [ARCHITECTURE.md](../../ARCHITECTURE.md) §12, which with [DECISIONS.md](../../DECISIONS.md) is authoritative.\
**Reviewer:** review-transport-1. I did not write the design.
**Lens:** app-key leakage (redirects, logs, `Mirror`, `dump`, errors, diagnostics), allow-list and HTTPS bypasses, the 403 ambiguity, ETag/304 and URLSession cache staleness, gzip vs `Content-Length` vs `byteSize`, size-cap bypass, truncated bodies, trusting resumed bytes, and path escape via `remotePath`.
**Read:** CLAUDE.md; SPEC §2.3, §4.1–4.3, §5.2–5.5, §5.9, §6 (P-10, P-11), §7.3, App. B and C; `docs/RECON.md`; `docs/DECISIONS.md`; `docs/BASELINE.md`; `docs/design/transport.md` (all of it); the parts of `store.md` (§2.6, §5.1–5.5, §6.3) and `sync.md` (§3, §6, §8) that transport couples to. I also read the drafter's prototype in `.build-probe-transport/pkg/Sources/TransportProto/` and its `out/experiments-final.txt` (read-only).
**Evidence:** every **RV-n** below was run in this session on Apple Swift 6.4 / macOS 27.0 (arm64). Probe sources and raw output are in `.build-probe-review-transport-1/` (git-ignored): `server.py` (a scriptable loopback HTTP/1.1 server with two listeners, A and B, that logs every request's headers), `client.swift` (URLSession probes), `tc/` (compile probes) and `out/`. §5 shows how to reproduce them. Every runtime fact here comes from the **macOS host**. iOS runtime behaviour is **not verified**.

> **Residue notice (owner directive).** URLSession download tasks write `CFNetworkDownload_*.tmp` into the per-user temp directory (`getconf DARWIN_USER_TEMP_DIR`), and they ignore `TMPDIR` (RV-9). My probes therefore left 8 files there, about 44 MiB: `CFNetworkDownload_{uVjgMY,3Vlz3z,nL3Fpg,oCBw1U,4uAPQY,mQpZuS,o47q6l,bWq5oP}.tmp`. `out/residue-status.txt` also lists 3 files (`ATcmnX`, `miIS1P`, `qlJjVk`) that appeared during my run but came from another process. I did not delete them, because CLAUDE.md limits `rm` to `.build*`. The `purged-resume` probe did delete one file (`CFNetworkDownload_a0OuGe.tmp`) that my own process had created seconds earlier; that deletion was the point of the experiment. Finding **TR1-2** explains why every loopback test run, including the drafter's E-runs, does the same: that directory already held **756 such files, 816 MiB**, all written today from 04:55 onward. I stopped running URLSession probes when I found this.

---

## 0. Summary

| ID | Sev | Finding | Violates |
|---|---|---|---|
| TR1-1 | **critical** | The deterministic staging name `staging/<TransferID>.part` is shared by concurrent writers. sync.md single-flights per **AssetID**, not per content, so two manifest entries with the same checksum run two transfers with one `TransferID`. `adoptDownload` *replaces* the `.part` (before its size check) while the store's `publish` is hashing it by path and is about to rename it by path. | I-1, R-STO-3, R-INT-2, H-3, H-6 ("not duplicated") |
| TR1-2 | major | The partial bytes of every interrupted foreground download are orphaned **outside the store root**, in the OS temp directory: plain `cancel()`, SizeGuard aborts, `invalidateAndCancel()`, process exit, and discarded resume data all leave them (RV-5…RV-9). Nothing in the design can delete them. The store cannot see them, and store §2.6 7d deletes every lone `.resume`. | R-STO-1, R-CLN-3 (D-7), R-CLN-9, R-CLN-4 / R-SYN-11, R-NET-8, owner directive (tests) |
| TR1-3 | major | Checksum-less (legacy `l-`) entries are resumed and then published with **no hash at all**. A spliced, truncated or close-delimited short body becomes a permanent "unverified" blob. | R-NET-8, R-NET-7, R-INT-2 spirit |
| TR1-4 | major | Unusable resume data fails with **−1002 `unsupportedURL`** and `originalRequest == nil` (RV-4). The design maps that to `rejected(.invalidURL)`, never to `resumeRejected`, and the tag carries no "resumed" bit. Rule 3 cannot be implemented statelessly, so the asset fails every run for up to `stagingMaxAge` (72 h). | R-NET-8, R-NET-6, R-SYN-6 |
| TR1-5 | major | A key rotation strands resume data that embeds the **old** key. Each resumed request sends it, gets 403 with an empty body (`keyRejectedLikely`), and three such assets open the auth breaker. Each asset is also quarantined `untilEntryChanges`, which is permanent for content-addressed entries. | R-SYN-5 (false trip), R-NET-6 |
| TR1-6 | major | After the transport itself strips the key on an allow-listed cross-origin redirect, a keyed target answers 403 with an empty body. The evidence cannot say "key not sent", so the engine treats our own policy as key rejection: breaker plus permanent quarantine. | R-NET-6, R-SYN-5 |
| TR1-7 | major | Hint precedence. `purpose == .manifest` is checked **before** body shape. An S3 XML 403 proves the request already passed the CloudFront Function (the key was accepted), but a deleted or renamed `manifest.json` still yields `keyRejectedLikely`, and the breaker opens for every user. | R-NET-6 ("never silently one of them"), R-SYN-5 |
| TR1-8 | major | Size cap under compression. The announced size is **−1** for any `Content-Encoding` (RV-2; this contradicts §7.1's sentence). A gzip bomb's **first** `didWriteData` already reports **16.8 MB written against a 1 MiB cap** (RV-3), and the overshoot is then leaked by TR1-2. `byteSize` is never used to abort early. | R-NET-7 ("aborted early"), §6 claim, H-9 spirit |
| TR1-9 | minor | Rule 3's pre-resume policy check reads `originalRequest`, but the resumed request goes to the archived **`currentRequest`** (RV-1). | R-NET-4 (allow-list on resume) |
| TR1-10 | minor | How `baseURL` + `remotePath` become a URL is unspecified. The two obvious joins disagree on `?`, `#`, `%2e%2e` and `./` (RV-10). | R-SEC-2 defence in depth, R-NET-4 |
| TR1-11 | minor | −1012/−1013 and HTTP 401 map to a *confirmed* key rejection, so the breaker opens at once. CloudFront never sends 401 (§2.3), so these come from proxies or captive portals. | R-SYN-5 (false trip) |
| TR1-12 | minor | The `PackID` regex `[A-Za-z0-9._-]{1,64}` admits `.` and `..`, and `PackLocation.init?(remotePath:)` validation is unspecified on a public type. | R-SEC-2 defence in depth |
| TR1-13 | minor | Prototype vs design: allowed hosts are not trailing-dot-stripped; pause is classified **before** oversize; resume data is stored twice per pause by two callbacks; staging GC cannot express foreign (temp) names. | R-NET-4, R-NET-7, R-CLN-3 |

Areas that held, and exactly what I tried, are in §3.

---

## 1. Critical

### TR1-1 · One staging name, several writers: `adoptDownload` overwrites a `.part` that `publish` is hashing

**Design claims.** §4.3 (l. 567): *"The engine single-flights per content (sync.md §6), so two live transfers never share an id. A stale `.part` from an earlier attempt is replaced by the rename. This is safe because the bytes are content-addressed and hash-checked at publish."* §3.2 (l. 217): `transfer` *"never creates a second OS task for an id that is already live"*. §10.5 (l. 829) and §10.8 (l. 859) deliberately run two attempts of one id at once ("the first verified result wins").

**Why that does not hold.**
- sync.md does **not** single-flight per content. `Job.id` is an `AssetID`, and waiters join `jobs[waiter.asset]` (sync.md §6.1–6.2, l. 350, 496). The planner deduplicates only against a blob that is **already present**: `if let c = e.checksum, snapshot.hasBlob(checksum: c) { reuses }` (sync.md l. 293). Two absent entries with the same checksum therefore become two fetches. SPEC §4.3 lists "identical bytes dedupe" as a feature, so this input is expected.
- The foreground backend is stateless ("no table") and creates a task on every `start` (prototype `ForegroundBackend.swift` `start`). Nothing backs the "never a second OS task" promise. Implementing it with `await session.allTasks` would race: two concurrent `transfer()` calls both see no task, then both `resume()`.
- `adoptDownload` renames over the existing name and runs **before** `classifyFinished` checks the size (§4.3 flow, l. 556–557).
- The store hashes **by path**, one 1 MiB unit at a time (`fileSystem.read(from: url, offset:, maxLength:)`, store.md §5.1), and then renames **by path** (`rename(.part → blob, .exclusive)`, store.md §5.3). Nothing pins the inode between the hash and the rename.

**Timeline A** (default configuration: foreground only, no crash):
1. Manifest M has entries `X` and `Y`, both with checksum `C` and both absent. The plan has two fetches, so the engine runs jobs X and Y, each calling `transfer(id: c-C, attempt: 1)`. URLSession now has two tasks with identical tags.
2. Task X finishes. On the delegate queue, `adoptDownload` renames `tmpX → staging/c-C.part`, and `.staged` goes to X's mailbox.
3. Engine job X calls `store.publish`. `itemInfo` reports a size equal to `byteSize`, so it passes. Hash units 0…k−1 read X's inode **by path**.
4. Task Y finishes (same server, same size, so typically within the same second). `adoptDownload` renames `tmpY → staging/c-C.part`, replacing X's inode **before** anyone checks Y's size.
5. X's hash units k…n now read Y's inode. Then X's metadata unit runs `rename(staging/c-C.part → blobs/…/C.ext)`, which moves **Y's inode** into `blobs/`.
6. Outcomes:
   - (a) Y is honest. The bytes are equal, but Y's own `publish` finds `staging/c-C.part` gone (ENOENT), so Y fails spuriously and re-downloads.
   - (b) Y is truncated (a close-delimited short body, E-4b shape). X's digest covers a mix of X and Y, so X fails `checksumMismatch` although X's bytes were good. R-INT-3 quarantines X, and after 3 repeats X is `failed(.integrity)` until its entry changes, which is never for a content-addressed key.
   - (c) **Y has the right size but a corrupt range, and the rename-over lands between X's last hash unit and X's rename.** Example: the E-5 "liar" edge, which serves a tampered body under the same ETag; RV-1 shows that a resumed request carries `If-Range` with that ETag. `blobs/C.ext` now holds bytes that were never hashed. **I-1 is broken**, and the snapshot serves the file as verified.

**Timeline B** (default configuration, after a crash):
1. Attempt 1 of `id` loses its connection, and `staging/id.resume` is stored. Attempt 2 resumes, completes, and `adoptDownload` creates `staging/id.part`.
2. The app is killed before anyone deletes `id.resume`. The design never says who deletes it, or when ("deleted on completion", §5.4).
3. At launch, §10.5 row 3 (`.part` → `.adoptStaged`) **and** row 4 (`.resume`, no live task → `.resume`) both match, since nothing makes them exclusive.
4. The resume data's tmp partial was consumed by attempt 2. URLSession then **silently restarts with a full GET** (RV-8). The result is a whole second download of a file already complete in staging, and its `adoptDownload` renames over `id.part`, possibly while step 3's `publish` is still hashing it, which reopens 6(b)/(c).

**Timeline C** (opt-in background): §10.5 row 6 and §10.8 run a live OS task and a publish of the same `.part` at once, by design.

**Violates:** I-1, R-STO-3 / R-INT-2 (the bytes published are not the bytes verified), H-3 (X fails because of Y), H-6 ("not duplicated").

**Smallest fix:**
1. Make the staging name unique per start: `staging/<TransferID>.<attempt>.part|.resume`, with `attempt` taken from an **engine-global** monotone counter (persisted as a high-water mark in the index), not a per-id counter. It stays deterministic and self-describing (H-6, C4).
2. `adoptDownload` uses `renamex_np(RENAME_EXCL)` (store.md D2 already has it in the seam) and never replaces. EEXIST means `insufficient uniqueness`, which is a bug.
3. Either the engine coalesces jobs by `TransferID` (a content key), or the transport rejects a duplicate live id inside one actor. In both cases, delete the "never a second OS task" sentence until a mechanism backs it.
4. In the §10.5 table, a complete `.part` makes `.resume` for the same id `discard`.
5. A store-side follow-up for the store reviewers: hash one opened descriptor and `fstat`-compare `(dev, ino)` with the path right before the rename.

Fixes 1 and 2 alone close timelines A–C.

---

## 2. Major

### TR1-2 · Interrupted downloads leave their partial bytes outside the root, and nothing can collect them

**Design claims.** §4.1 (`.ephemeral`, *"nothing is written outside the store root (R-STO-1)"*). §5.4 decision (a): *"persist [resume data] in `staging/<id>.resume` … inside the protected, backup-excluded root"*. store.md §6.3: *"nothing goes to `tmp` and nothing leaks"*.

**Measured (macOS 27 host):**

| Probe | What happened to the `CFNetworkDownload_*.tmp` partial |
|---|---|
| RV-5 `fresh-cancel`: plain `cancel()` at 1 MiB of 4 MiB | **still there, 1,048,576 bytes**, 0 s / 0.5 s / 2 s later |
| RV-6 `cancel-invalidate`: plain `cancel()`, then `invalidateAndCancel()` (R-SYN-15 shutdown) | still there after invalidation, **and after the process exited** |
| RV-3 `bomb-cancel`: SizeGuard-style `cancel()` on a gzip bomb, cap 1 MiB | **16,781,096 bytes left** |
| RV-7 `tempfile`: `cancel(byProducingResumeData:)` | the partial is in `NSTemporaryDirectory()`, not in `staging/`, and the resume archive points at it |
| RV-7: hand the resume data back with `downloadTask(withResumeData:)` + `cancel()` | still there |
| RV-7b `running-cancel`: resume it, wait until it runs, then plain `cancel()` | still there (1,114,112 bytes) |
| RV-9 `TMPDIR` pointed inside the repo | ignored; URLSession still writes to `DARWIN_USER_TEMP_DIR` |
| the drafter's and other agents' loopback runs today | **756 files, 816 MiB** in that directory |

**Timeline (production, default configuration):**
1. The user scrolls the carousel. R-CAR-3 cancels prefetches that leave the ±2 window. Each consumer cancellation calls `onTermination` → `task.cancel()` (§4.5).
2. Each cancelled task leaves its partial in the app's `tmp/`. For video pages that is megabytes each.
3. `shutdown()` → `invalidateAndCancel()` leaves the partial of every in-flight transfer (RV-6).
4. A resumable failure stores `.resume` in staging, while the bytes stay in `tmp/`. store.md §2.6 step 7d keeps only `(.part, .resume)` **pairs**, but download tasks never produce a partial `.part`. So at the next launch every lone `.resume` is deleted (resume across relaunch never happens) and its partial is orphaned. 7d also requires a "parseable" `.resume`, which the store cannot parse without reading URLSession's private archive (R-SEC-3).
5. Free space shrinks. `StorageReport` (R-CLN-9) does not show it. R-SYN-11 / R-CLN-4 react to the lower free space by **evicting legitimate assets** to pay for the module's own leak. Growth is bounded only by an unspecified OS purge of `tmp/` while the app is not running.

**Also:** every `verify.sh` run (×3 repeats plus TSan, Q-5) will leave the cancellation, FIN-drop, oversize and pause tests' partials **outside the repository**, against the owner directive.

**Violates:** R-STO-1 (MUST), R-CLN-3 / D-7 (MUST: "partial files … without an owner are removed"), R-CLN-9, R-SYN-11/R-CLN-4 (wrong eviction input), R-NET-8 (no resume across relaunch, given store 7d), owner directive (test runs).

**Smallest effective fix:** RV-5…RV-7b exhausted every URLSession call that could delete the partial; none does. The only fix that stops the leak is for **foreground transfers to use data tasks that append to `staging/<id>.<attempt>.part` through the `StagingSink`**, and to resume them with the transport's own `Range` + `If-Range`, keeping the ETag in a sidecar `.resume` whose format we own. Download tasks remain only in the opt-in background session (S-2/§10).

**TC-RV1** (`tc/datatask_mailbox.swift`) compiles a `final class DataTaskMailbox: NSObject, URLSessionDataDelegate, Sendable` that holds `let handle: FileHandle` and a `Sendable` sink, with `didReceive response` and `didReceive data`. With `-swift-version 6 -warnings-as-errors StrictConcurrency=complete` at **iOS 15 and macOS 12** it gives **exit 0 and 0 diagnostics**, so the change costs no escape.

This reverses §7.2 rule 5. Its "stateful" objection is answered by the immutable mailbox, and the background objection by keeping download tasks there. The same change also removes TR1-4 (no private archive), TR1-5 and ADR-T4 (no key at rest: the sidecar holds no request), and TR1-8 (b) (an aborted body stays inside staging and GC sees it), and it makes `.part` mean what store.md already assumes it means. P-10/P-11 are unaffected (same session, same connections).

### TR1-3 · Checksum-less entries: resumed and truncated bytes are trusted with no hash

**Design claims.** §7.2 rule 2 (l. 699): *"Resumed bytes are never trusted. … the store hashes every staged file."* For legacy entries there is nothing to hash against: store.md §5.3 publishes them with `verified: false` when `allowUnverifiedAssets` is true (the default, R-INT-5). R-MAN-5 re-downloads them **only when `remotePath` changes**.

**Timeline:**
1. A legacy entry L has no `checksum` and possibly no `byteSize` (both are optional in the wire format, RECON §5). Its `TransferID` is `l-…` and its key is not content-addressed, so the bytes behind L's `remotePath` may change between attempts.
2. Attempt 1 loses its connection, and resume data is stored.
3. Attempt 2 resumes: `Range` + `If-Range: <ETag>` (RV-1, E-5). An edge that ignores `If-Range` or serves a tampered tail under the same ETag (E-5's liar) produces a spliced file of the right size.
4. `classifyFinished` passes the size check (or there is no `byteSize`). `publish` finds no checksum, so the file is published `unverified` and is **never re-fetched** (R-MAN-5).
5. Without `byteSize`, a close-delimited short body (E-4b shape) is also accepted in full. A `.part` whose `classifyFinished` failed is not deleted by the delegate (§4.3 flow), so a crash leaves it for §10.5 `.adoptStaged`, which publishes it unhashed.

**Violates:** R-NET-8 ("never trusted without the final hash": for these entries there is no final hash), R-NET-7 (truncation undetectable), R-INT-2 spirit.

**Smallest fix:**
- A `TransferID` whose kind is `legacy` is **never resumed**. `pause()` uses plain `cancel()` and reports `.paused(resumable: false)`, and any `.resume` for it is discarded.
- Checksum-less transfers request `Accept-Encoding: identity` (RV-11 shows the header is honoured). They require `expectedContentLength ≥ 0` and staged size == `Content-Length` (meaningful once the encoding is identity), and == `byteSize` when present.
- The delegate discards the staged file synchronously whenever `classifyFinished` fails.

### TR1-4 · Unusable resume data → −1002 → `rejected(.invalidURL)`, so the "one fresh restart" never happens

**Design claims.** §7.2 rule 3 (l. 700): *"A resumed task that fails before any response (unusable data) … → `transient(.resumeRejected)` → `discardResumeData` → one immediate fresh restart."*

**Measured.** RV-4 `garbage-resume`: `downloadTask(withResumeData: "not resume data")` → `didComplete NSURLErrorDomain −1002` (underlying `kCFErrorDomainCFNetwork −1002`). RV-4b `truncated-resume`: a real 7,980-byte blob cut in half gives `originalRequest=nil currentRequest=nil` before `resume()`, then **−1002** with no response.

**Timeline:**
1. `staging/id.resume` is unusable. Causes include a torn or truncated write ("SYNCHRONOUS, best effort", §3.3), the 256 KiB truncation path, or an OS update that changes the private resume-data format.
2. The prototype's pre-resume check `policy.check(Origin(task.originalRequest?.url))` sees `nil`, giving `.invalidURL` and `rejected(.invalidURL)`. Without that check, −1002 maps through §3.4.2 row "−1000 / −1002 → `rejected(.invalidURL)`" to the same result.
3. The tag has no "resumed" field (`ztak1 <id> <attempt> <expected> <limit> <purpose>[ pause]`), so the stateless classifier cannot tell this from a genuinely bad URL. It never yields `resumeRejected`, never discards the blob, and never restarts.
4. §3.4.3 maps `rejected` to `failed(.nextRun)`. The next run loads the same `.resume` and fails the same way. With store 7d as amended by X-T6, the `.resume` is claimed every run and survives until `stagingMaxAge` = **72 h** (store.md l. 717).

**Violates:** R-NET-8 (resume must not block the download), R-NET-6 (wrong class), R-SYN-6 (a recoverable asset fails for days).

**Smallest fix:** add an `r` flag to the tag when `start` uses resume data. For a resumed task, any error with `task.response == nil`, and a nil `originalRequest`/`currentRequest` before `resume()`, classifies as `resumeRejected`. That discards the data and restarts once without it inside the same `transfer()`. Under TR1-2's data-task design the problem disappears, because the `.resume` format is ours and validated.

### TR1-5 · A key rotation turns every stored resume into a 403 storm that opens the auth breaker

**Design claims.** §5.4 decision (a), and F-15 (l. 1064): *"Resumed request 403 → evidence → the engine counts it; resume data discarded after any auth failure."*

**Timeline:**
1. Version N of the app is paused mid-sync of 3 or more large assets. Their `.resume` files embed key K1: E-5 shows `resumeDataContainsAppKey=true` and `keyOnResumedRequest=true`, and RV-1 shows `containsCanary=true`.
2. App update N+1 ships key K2, and the CloudFront Function now rejects K1.
3. At launch, §10.5 `.resume(id)` resumes each one. The archived request **re-sends K1**, because resume data cannot carry new headers. Each gets a 403 with an empty body, so `forbiddenAmbiguous(bodyBytes: 0)` → `.keyRejectedLikely`.
4. sync.md §8.1 sets each asset to `failed(.untilEntryChanges)`, which is **permanent** for content-addressed entries. sync.md §8.3 opens the auth breaker on 3 distinct ambiguous 403s, with a cooldown of 300 s doubling to 3,600 s. The new key K2 is never tried until the half-open probe, and the quarantined assets never are.

**Violates:** R-SYN-5 (the breaker must trip on repeated authentication failures; K2 never failed), R-NET-6 (the evidence omits that the request carried a stale archived key).

**Smallest fix:**
- Write `.resume` as our own envelope: `magic ‖ fingerprint ‖ URLSession bytes`, where `fingerprint = SHA-256("ztak-resume" ‖ key ‖ origin(baseURL))[0..16]`, via CryptoKit at iOS 13+. A mismatch at load means discard before use.
- Add `resumed: Bool` to `ForbiddenEvidence`, so a resumed-request 403 triggers one fresh restart and never counts toward the breaker or the quarantine.
- The fingerprint reveals nothing new: the raw key already sits in the same file (ADR-T4).

### TR1-6 · A 403 caused by our own key stripping is reported as a probable key rejection

**Design claims.** §5.2: on a cross-origin redirect to an **allow-listed** host the request is followed and *"otherwise strip it"*; §16.3 has the test *"a cross-host redirect to an allow-listed host is followed without the app key"*. §3.4: 403 → `forbiddenAmbiguous(ForbiddenEvidence(purpose, bodyBytes, contentTypeIsXML))`.

**Timeline:**
1. The owner sets `additionalAllowedHosts = ["d2.cloudfront.net"]`, for example while migrating to a new distribution that d1 301-redirects to, with the same CloudFront Function.
2. A GET to d1 gets a 301 to d2. d2 is allow-listed and its origin differs, so the request is followed **without the key**: the E-6a behaviour, and RV-1 confirms the key is absent on the hop.
3. d2's Function answers 403 with an empty body, so `.keyRejectedLikely`.
4. The engine counts it as a key problem. On assets that means `untilEntryChanges` (permanent) plus the auth-suspect counter, and after 3 the breaker opens. On the manifest, the breaker opens at once (§3.4.3).

The key was valid; the transport withheld it, and nothing in the evidence says so.

**Violates:** R-NET-6 (a 403 is reported as "key rejected or object missing", but here it is neither), R-SYN-5.

**Smallest fix:** add `keyPresented: Bool` to `ForbiddenEvidence`, read as **presence only** from `task.currentRequest?.value(forHTTPHeaderField: keyHeaderName) != nil`. When a key is configured but was not presented, classify the 403 as `rejected(.redirectRefused(.keyWithheldOnRedirect))`: no breaker, no quarantine, counted in metrics. Document that, by construction of R-NET-4, a keyed origin is unreachable through a cross-origin redirect.

### TR1-7 · The 403 hint lets "it was the manifest" override "S3 answered"

**Design claims.** §3.4 (l. 373): *"a manifest 403, or an empty body → `.keyRejectedLikely`; an XML body → `.objectMissingLikely`"*. Prototype `Contracts.swift:234-238` checks `purpose == .manifest` **first**.

**Why it is wrong.** By §2.3, a missing or unknown key is answered by the CloudFront Function with a 403 and an **empty body**, before S3 is reached. An S3 `AccessDenied` **XML** body therefore means the Function accepted the key and S3 refused, so the object is missing (or OAC is misconfigured). That is near-conclusive, not "likely", whatever the purpose.

**Timeline:**
1. A publish uploads media first and swaps `manifest.json` last. In between, or after an operator deletes the manifest, `GET manifest.json` returns 403 `application/xml`.
2. The hint returns `.keyRejectedLikely`, because the manifest rule wins.
3. sync.md §8.1/§8.3 opens the breaker **at once** for every client, and every resolve fails fast with `.authRejected` for 300–3,600 s, although the key works and all assets are fetchable.

The same XML 403 on an object, during a publish race or edge negative caching, produces `untilEntryChanges`, which is permanent for content-addressed keys. That part is sync's policy, but this hint is its only input.

**Violates:** R-NET-6 (the engine ends up acting on one reading of an ambiguous 403 while contrary evidence is discarded), R-SYN-5.

**Smallest fix:** evaluate the body first. XML → `.objectMissingLikely`. Empty → `.keyRejectedLikely`. Otherwise `.undetermined`, and only then use `purpose == .manifest` to break the tie. Ask sync.md to open the breaker on a manifest 403 only when the hint is `.keyRejectedLikely`, and to use a long backoff rather than `untilEntryChanges` for `.objectMissingLikely`.

### TR1-8 · Under compression the early abort is blind, the bomb overshoots 16×, and `byteSize` is never used

**Design claims.** §7.1 (l. 686): *"In E-3 URLSession reported `totalBytesExpectedToWrite = 315000` under gzip … the slack is a safety margin"*. §6 item 6: the 32 MiB cap is *"enforced while streaming"*.

**Measured:**
- RV-2 `gzip` (`Content-Length` 988 encoded, 315,000 decoded): `didWriteData expectedToWrite=-1`, `countOfBytesExpectedToReceive=-1`. The drafter's **own final run** also says `announcedValuesSeen=[-1]` (`out/experiments-final.txt`); the 315000 figure is from an earlier run.
- RV-3 `bomb-cl` / `bomb-nocl` (64 MiB of zeros gzipped, cap 1 MiB): the **first** `didWriteData` reports `totalBytesWritten=16,757,360` and `16,781,096`. That is ≈ 16× the cap on disk before the delegate can react. The cancelled file is then leaked (TR1-2).
- Counter-check: the −999 re-derivation **does** hold. `countOfBytesReceived` counts decoded bytes, so `REDERIVE oversize=true` in both runs (see §3).

**Timeline:**
1. CloudFront compresses `image/svg+xml` and JSON by default. Assume a misconfigured or hostile origin.
2. For any compressed response, the announced-size branch of `SizeGuard` never fires.
3. Each abort writes cap + ~16 MiB and leaks it.
4. With a known `byteSize` (the tag already carries `expected`), a wrong body is still downloaded up to `maxAssetBytes`, which may be gigabytes, before `sizeMismatch`. This repeats on every R-INT-3 attempt.

**Violates:** R-NET-7 ("aborted early" holds only for identity responses), the §7.1/§6 evidence claims, H-9 spirit.

**Smallest fix:**
- Assets send `Accept-Encoding: identity`. RV-11 shows URLSession honours it and the server received `accept-encoding: identity`. HEIC, PNG, JPG, MP4 and MP3 gain nothing from gzip, and identity also makes TR1-3's `Content-Length` check meaningful.
- `SizeGuard` aborts at `written > min(limit, expected)`, and at `announced >= 0 ∧ announced ≠ expected` when `expected` is known.
- The manifest keeps gzip and the written-bytes cap.
- Correct the §7.1 sentence.

---

## 3. Minor

### TR1-9 · Rule 3 checks the wrong request
RV-1 `redirect-resume`: an original GET to A (with the key) gets 302 → B; the delegate strips the key, and B drops after 1 MiB. Before `resume()`, the resumed task reports `originalURL=A keyOnOriginal=true` and `currentURL=B keyOnCurrent=false`. The resumed GET with `Range: bytes=1048576-` and `If-Range: "v1"` went to **B**. `willPerformHTTPRedirection` was **not** called (0 calls).

So the key does **not** leak on resume, which is good. But §5.3 rule (3) and prototype `ForegroundBackend.swift:74` validate `originalRequest` (A). If the allow-list shrank between runs to exclude B, the resumed request still goes to B. If it shrank to exclude A only, a harmless resume is refused.

**Fix:** require `check(currentRequest) == nil ∧ check(originalRequest) == nil`; if either is `nil`, apply TR1-4.

### TR1-10 · The `baseURL` + `remotePath` join is unspecified
RV-10, with base `https://d111.cloudfront.net/prefix/`:

| `remotePath` | `URL(string:relativeTo:)` | `appendingPathComponent` |
|---|---|---|
| `media/x.png?v=1` | `…/media/x.png?v=1` (a **query**) | `…/media/x.png%3Fv=1` |
| `media/x#frag` | `…/media/x#frag` (a **fragment**) | `…/media/x%23frag` |
| `media/%2e%2e/%2e%2e/manifest.json` | passed through encoded (the edge may normalise it) | `%252e%252e` |
| `./media/x` | resolved to `…/media/x` | `…/./media/x` |

On macOS 27 a space is percent-encoded by `URL(string:)`. On iOS 15/16, `URL(string:)` is documented to return `nil` for such input (not verified on a device). R-MAN-2 forbids neither `?`, `#`, `%`, `\` nor spaces.

The allow-list check in `makeRequest` stops any cross-host escape, so this is not a key leak. Still, the same manifest can address different objects on different OS versions, or escape the `prefix/` path on the same host.

**Fix:**
- Specify the join as per-`/`-segment `appendingPathComponent`.
- Reject `%`, `\`, `?`, `#`, empty, `.` and `..` segments in `HTTPRemoteSource`, as defence in depth below R-MAN-2.
- For assets, assert `Origin(url) == Origin(baseURL)` and that the URL's path has `baseURL.path` as a prefix. This is stricter than the allow-list, because assets never legitimately start on another host.

### TR1-11 · 401 and −1012/−1013 are not evidence about our key
§3.4.2 maps −1012/−1013 to `authentication(.unauthorized(0))`, and sync.md §8.3 opens the breaker on "any 401". By §2.3 our origin never challenges: a bad key is a 403. These codes therefore come from authenticating proxies, captive portals or TLS client-certificate middleboxes. On such a network the breaker trips for 300 s or more, while the condition heals on a path change.

**Fix:** use `transient(.authenticationChallenge)`, re-queued on a path edge (R-SYN-13), and keep `unauthorized` for nothing the origin can send. I did not reproduce −1012/−1013 here (no proxy available).

### TR1-12 · `PackID` admits `.` and `..`
`[A-Za-z0-9._-]{1,64}` (§11.1, l. 870) accepts `"."` and `".."`, and `PackLocation.init?(remotePath:)` is public with unspecified path validation. R-MAN-2 runs upstream, but these are public types.

**Fix:** reject `.` and `..` ids, and re-apply the R-MAN-2 path rules (relative, no `..`, no empty segment, no control character) inside `PackLocation`.

### TR1-13 · Prototype and design disagree in four places
- (a) `TransportSecurityPolicy.init` lowercases allowed hosts but does **not** strip a trailing dot (`Security.swift:57`), while `Origin` does. A `baseURL` like `https://d.cloudfront.net./` then rejects every request with `hostNotAllowed`.
- (b) `didCompleteWithError` tests `pauseRequested` **before** the oversize re-derivation (`SessionDelegate.swift:126` vs `:130`), against §3.4.2's order. If a SizeGuard abort races a preemption `pause()`, the result is `.paused(resumable: false)`, re-queued with no integrity backoff, so the oversize download repeats on every preemption.
- (c) Resume data is stored twice per pause: `URLSessionTransferHandle.pause` (`ForegroundBackend.swift:168`) and `didCompleteWithError` (`SessionDelegate.swift:121`). RV-7 shows both carry identical bytes. Two synchronous writers of `<id>.resume` from callbacks whose queue is unspecified race on the atomic-write temp name.
  - **Fix:** store only in `didCompleteWithError`, and make the pause completion handler a no-op.
- (d) A crash between the temp write and the rename of `storeResumeData` leaves a foreign name in `staging/`. §10.5 can only `discardStaged(StagingFileName)`, so `collectStaging` must delete every non-`StagingFileName` entry.

---

## 4. Areas that held (what I tried)

| Area | Attack | Result |
|---|---|---|
| Key on resume after a stripped redirect | RV-1: key, then a cross-origin 302 that strips the key, then a FIN mid-body, then resume | The resumed GET went to B **without** the key; the redirect delegate was not re-entered. **Holds** (the policy-check issue is TR1-9). |
| Key in reflection surfaces | RV-12: `dump` / `String(reflecting:)` of a `URLSessionDownloadTask`; an `NSError` whose `userInfo` holds the task and the URL; `URLError(_nsError:)` | No leak in any of them. `dump` leaks only when a `URLRequest` **value** is reachable (a struct or class holding one, `dump(task.originalRequest)`), which §5.4 already forbids storing. **Holds**, provided the canary test also `dump`s every handle and event type. |
| Key in resume data at rest | RV-1 | `containsCanary=true` (as E-5 found). Accepted risk under ADR-T4; TR1-5 adds the rotation consequence, and TR1-2's fix removes it. |
| Oversize re-derivation at −999 under gzip | RV-2 and RV-3: compare `countOfBytesReceived` with decoded and encoded bytes | `countOfBytesReceived` **is decoded** (315,000; 16.7 MB). The re-derivation reports oversize correctly with and without `Content-Length`. **Holds.** |
| Cap counts resumed prefix | RV-7b | `totalBytesWritten` of a resumed task includes the prefix (1,114,112 = 1 MiB + 64 KiB), so the cap covers the whole file. **Holds.** |
| Resume after the OS purged the tmp partial | RV-8 `purged-resume`: delete the partial, then resume | URLSession silently sent a **fresh GET with no `Range`**: no error and no stuck state. **Holds** (but see TR1-1 timeline B). |
| 304 / cache staleness | Read the prototype configuration (`.ephemeral`, `urlCache = nil`, `.reloadIgnoringLocalCacheData` per request); ran every probe with it. Considered an ETag committed without its manifest (store `apply(manifest, etag:)` commits both in one generation), a tier switch (the `"sha256:…"` pseudo-ETag cannot equal an S3 MD5 ETag), OS purge (the ETag lives in the root, R-STO-2), and header injection via ETag (printable-ASCII validation) | No stale-copy path found. **Holds.** |
| HTTPS-only and the allow-list on redirects | Read `RedirectPolicy.decide`/`check`; Location forms `//host`, `file:`, userinfo, uppercase or trailing-dot hosts, port-only change; IPv6 literal | Each refuses or strips correctly. Production cannot express plain HTTP (`loopbackTesting` is `package`). **Holds**, except TR1-13 (a). |
| `taskDescription` races | `NSURLSession.h:785` declares `@property (nullable, copy)`, which is atomic | The pause flag write is safe. **Holds.** |
| Data-task mailbox at the floor | TC-RV1 | Compiles clean at iOS 15 and macOS 12 with no escape (supports TR1-2). |
| `Accept-Encoding` override | RV-11 | The request-level `identity` reached the server. **Holds** (supports TR1-3 and TR1-8). |

**Not verified:** any iOS **runtime** behaviour, in particular whether iOS also leaves `CFNetworkDownload_*.tmp` after `cancel()` (TR1-2 was measured on the macOS host). Also: CloudFront's compression and `Range` behaviour on compressed objects; real −1012/−1013 sources; `URL(string:)` with spaces on iOS 15/16.

---

## 5. Reproduction (`.build-probe-review-transport-1/`, sandbox disabled)

| ID | Command | Key output (`out/<mode>.client.txt`, server log `out/<mode>.server.jsonl`) |
|---|---|---|
| build | `xcrun swiftc -swift-version 5 -O client.swift -o out/client` | probe binary (Swift 5 mode: probe code only) |
| RV-1 | `bash run.sh redirect-resume` | `BEFORE resume(): originalURL=…/redir-to-b keyOnOriginal=true currentURL=…/b/file keyOnCurrent=false`; server: `B GET /b/file key=None range=bytes=1048576- if-range="v1"`; `redirect delegate calls during resumed attempt=0`; `containsCanary=true` |
| RV-2 | `bash run.sh gzip` | `expectedToWrite=-1 countOfBytesReceived=315000 countOfBytesExpectedToReceive=-1` |
| RV-3 | `bash run.sh bomb-cl`, `bomb-nocl`, `bomb-cancel` | `cap tripped at totalBytesWritten=16757360` / `16781096`; `REDERIVE oversize-from-task-counters=true`; leftover temp file 16,781,096 bytes |
| RV-4 | `bash run.sh garbage-resume`, `truncated-resume` | `-1002 underlying=kCFErrorDomainCFNetwork -1002`; `truncated: originalRequest=nil currentRequest=nil`; `response after failure: nil` |
| RV-5 | `bash run.sh fresh-cancel` | `after 2.0s: … CFNetworkDownload_4uAPQY.tmp: 1048576` |
| RV-6 | `bash run.sh cancel-invalidate` | partial exists after `invalidateAndCancel()` and after process exit (`ls` from the shell) |
| RV-7 | `bash run.sh tempfile`, `running-cancel` | partial in `NSTemporaryDirectory()`; survives `downloadTask(withResumeData:)` + `cancel()` and a running resumed task's `cancel()`; the pause completion data equals the `didCompleteWithError` userInfo data |
| RV-8 | `bash run.sh purged-resume` | after deleting the partial, the resumed task sent `GET /stall range=None` (a fresh restart) |
| RV-9 | `run.sh` sets `TMPDIR` inside the repo | ignored: paths still under `/var/folders/…/T/` |
| RV-10 | `bash run.sh urljoin` | the join table of TR1-10 |
| RV-11 | `bash run.sh identity` | server log `accept-encoding= identity` |
| RV-12 | `bash run.sh leaks` | `dump(URLSessionDownloadTask): leaks=false` … `dump(class holding task + URLRequest): leaks=true`, `dump(task.originalRequest): leaks=true` |
| TC-RV1 | `xcrun --sdk {iphoneos,macosx} swiftc -typecheck -target {arm64-apple-ios15.0,arm64-apple-macos12.0} -swift-version 6 -warnings-as-errors -enable-experimental-feature StrictConcurrency=complete -parse-as-library tc/datatask_mailbox.swift` | exit 0, 0 diagnostic lines at both floors (`out/tc-datatask-*.txt`) |
| residue | `getconf DARWIN_USER_TEMP_DIR`; `out/residue-status.txt` | 756 `CFNetworkDownload_*` files, 816 MiB in total, from 04:55 today |
