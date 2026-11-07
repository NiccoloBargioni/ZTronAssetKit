# Device test plan

What only a physical device can prove (SPEC §8): background session re-attachment, Apple-hosted packs through
TestFlight, low-storage behaviour and memory warnings; and every item Stages 1 to 3 marked device-only or UNVERIFIED
(§13 maps each source to its tests). **None of these tests has run.** Stage 3 ended with host and iOS Simulator runs
only (ADR-057, `docs/DECISIONS.md:574`, `:668-674`), and Stage 5 wrote this plan without a device. A result recorded
later goes into `docs/VERIFICATION.md` with the device, iOS build, app build and date.

## 1. Conventions

- **Test ids** are `DT-<area>-nn`. Each test gives its requirement IDs, why the host or the simulator cannot prove it,
  its setup, its steps, what to observe, and its pass criteria.
- **One iPhone covers every test except DT-FLR-01 and DT-FLR-02**, which need a second device on iOS 15 or 16 (the
  floor is iOS 15, R-ENV-2). The DT-APL tests need iOS 26 or later and TestFlight. DT-KIT-01, DT-MIG-01 and
  DT-MIG-02 need the carousel app adopted, which has not happened (Stage 4 was cancelled; S3-B-120).
- **Order.** §4 and §6 first: they hold SPEC §8's first and third areas and the one check due "before background
  transfers ship" (DT-BG-05). Then §7, §8, §10 and §9; then §5 (TestFlight), §11 (the second device) and §12 (the
  adoption).
- **Results.** A test that cannot run is recorded as not run, with the reason. A failure is recorded with its figures
  and goes to the owner; nothing here re-judges a requirement, and no figure here is a budget unless SPEC §6 says so.
- **References.** Requirement IDs are SPEC's; `P-n` are SPEC §6's budgets; `S3-B-nnn` are the Stage 3 backlog's items
  (`.build-orchestrator/s3-backlog.json`, in the main checkout); "§5 row :n" is a row of
  `docs/APPLE-API-VERIFICATION.md` §5 (UNVERIFIED behaviour) by its line. Source lines are this branch's; `Sources/` is
  unchanged since `d002758`.

## 2. Why the host and the simulator are not enough

- Two files hold the code that only runs on a device, and they are the only coverage exclusions:
  `ZTronAssetTransport/BackgroundSessionBackend.swift` and `ZTronAssetAppleHosted/LiveAssetPackBackend.swift`
  (`SPEC.md:106`; ARCHITECTURE §14, `docs/ARCHITECTURE.md:975`). The host suites drive their logic through fakes.
- Every other production line runs on macOS and on the iOS Simulator with fakes (`docs/ARCHITECTURE.md:976`): the
  fake file system, remote source, conditions and memory-pressure sources, and a manual clock. The fakes model
  ENOSPC, crash points and conditions; they do not model APFS, `nsurlsessiond`, UIKit or the OS's storage and memory
  policy.
- The test bundles build at iOS 17.0 and ran on the iOS 27.0 Simulator only; no iOS 15 simulator boots on the host
  (ADR-051, `docs/DECISIONS.md:392-394`; S3-B-130).
- Every C2 and benchmark figure is the build host's (Apple M3), not a device's (`docs/DECISIONS.md:582`, `:674`).

## 3. Common setup

### 3.1 Device and toolchain

- An iPhone on iOS 26 or later (needed for §5; any iOS from 15 serves the rest). Record its model, iOS build, total
  and free storage, and battery state. Low Power Mode off unless a test says otherwise.
- A Mac with Xcode 27.0 (27A266a) and Swift 6.4, the toolchain Stage 3 used (`docs/BASELINE.md:19`). Tests that set
  breakpoints use a Debug build; §9 uses a Release build.
- §5 needs App Store Connect access and TestFlight.

### 3.2 The probe app (needed; not in this repository)

Nothing in this repository embeds the kit, and the carousel app was not adopted (S3-B-120). The tests use a small host
app, "the probe app", which:

- creates one client with `AssetClient(configuration:environment:)`
  (`Sources/ZTronAssetKit/Facade/AssetClient.swift:33`) from `AssetEnvironment.live()`
  (`Sources/ZTronAssetKit/Composition/LiveEnvironment.swift:18`) and calls `start()` (`AssetClient.swift:182`);
- sets the environment's `logTap` (`Sources/ZTronAssetModel/Environment/AssetEnvironment.swift:33`; the protocol is
  `LogTap`, `Sources/ZTronAssetModel/Environment/EnvironmentSeams.swift:79`) to a tap that appends every kit line and
  both edges of every signpost interval to the probe log file with a wall-clock time (a tap receives every line and
  both edges, `Sources/ZTronAssetModel/Environment/AssetLog.swift:254`, `:287`, `:300`). `.live()` leaves the tap
  `nil` and keeps `OSLogSink` for the unified log (`AssetEnvironment.swift:29-33`), so the probe log does not depend
  on the unified log's retention. The probe log file has protection `none`, so it can be written before the first
  unlock (DT-STO-05);
- appends to the probe log every event of `events` (`AssetClient.swift:244`) and, on demand, `storageReport()`
  (`:317`), `metrics()` (`:346`) and `diagnosticReport()` (`:365`); the container is fetched with Xcode's Devices
  window ("Download Container");
- has controls for `sync(.force)` (`:259`), `resolve(_:)` of a chosen id (`:197`), `ensureAvailable(scope:)`
  (`:217`), `prefetch(_:)` (`:205`), `purge(_:)` (`:324`), `performMaintenance(timeBudget:)` (`:332`) and
  `shutdown()` (`:421`), and a debug "Exit" that calls `exit(0)`. Exit stands in for the system ending a suspended
  app; removing the app in the app switcher is a user force-quit, after which the system cancels the session's
  transfers (Apple's guidance on testing background sessions; confirm both in the current documentation);
- forwards `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to
  `handleBackgroundEvents(identifier:completionHandler:)` (`:435`) as README.md's snippet does (`README.md:288-293`),
  passing a wrapper that logs when the kit calls the handler; logs every hook call (identifier, time, return value)
  and each launch's application state; a build flag turns the forwarding off (DT-BG-03);
- registers a test cache through `register(_:)` (`:406`) whose `purge(level:)` logs each call, and can supply a
  UIKit-backed `MemoryPressureSource` (`EnvironmentSeams.swift:113`) through `AssetEnvironment.memoryPressure`
  (`AssetEnvironment.swift:28`); the UIKit implementation lives outside the module (R-CLN-11);
- has a "Filler" that writes, in 100 MB steps, and deletes one file in its own container outside the store root, and
  an allocation control that allocates and touches memory in 50 MB steps.

The probe app is test tooling, not part of the package; where it lives is the orchestrator's decision.

### 3.3 Origins and catalogs

- A test origin the tester controls: HTTPS, byte ranges (`Range` answered with 206; DT-BG-04, DT-BG-05), and an
  access log with each request's time, path, `Range` and `If-Range` headers, status and bytes sent. The access log is
  the main evidence for resumes and repeated downloads: it works on any network and for background transfers.
- Catalogs with checksummed entries: a small one (20 to 50 entries); a large one (10,000 entries, the C2 reference
  scale) for §9; three to five large files (50 to 200 MB) for §4.
- The background session takes only bulk transfers of a known size within the cap, never a Range resume, and never a
  request carrying the app key unless `keyRedirectExposure` is `.acceptedByOwner` (`README.md:297-301`;
  `Sources/ZTronAssetTransport/HTTPRemoteSource.swift:260-271`). Use a test origin that needs no key.
- DT-NET-04 alone needs the production CloudFront origin, which requires the key (`README.md:300-301`). The owner
  makes that build and supplies the key; it never goes into a log, a recorded result, a screenshot or this repository
  (R-SEC-1).

### 3.4 Observing

**What the kit exposes**, and nothing more:

- `events` (`Sources/ZTronAssetModel/Events/AssetEvent.swift:123-150`): snapshot changes, conditions (satisfied,
  expensive, constrained, Low Power Mode, thermal level), sync runs with their trigger and outcome, user and prefetch
  progress, non-bulk asset results, removals with their reason, breaker changes, maintenance reports, client start and
  shutdown. Progress events are coalesced newest-wins per key, terminal events are never dropped, and a bulk asset's
  result is folded into the run's progress and outcome (`:115-118`).
- `metrics()` (`Sources/ZTronAssetModel/Reports/Reports.swift:264`): bytes downloaded, manifest and asset requests,
  retries and failures by class (`FailureClass`, `:170`), promotions, preemptions, evictions, GC bytes, integrity
  failures, breaker trips. `storageReport()`: bytes by kind and state, staging, source copies, free space.
- `diagnosticReport()`: the configuration (the key shown as `<redacted>`,
  `Sources/ZTronAssetKit/Observability/DiagnosticReportBuilder.swift:68`), the engine's counts (lifecycle, running,
  preempting, jobs by state, queued by lane, tasks, timers, `watcherActive`, `memoryPressureObserverActive`;
  `:116-143`) and recent errors.
- Log lines, few and by category: `store` (OS purge detected, root check failed, commit failures, quota eviction,
  quarantine, a corrupt blob, legacy migration); `sync` (`failure <class> <hashed id>` at `.error`,
  `Sources/ZTronAssetSync/Engine/EngineJobs.swift:1218`; S1's `long purge turn: <ms> ms, <jobs> jobs, <groups> groups`
  at `.info`, `Sources/ZTronAssetSync/Engine/EngineCommands.swift:1012`); `transport` (manifest fetches only,
  `HTTPRemoteSource.swift:154-170`); `apple` (catalog reads, pack availability, releases, update checks).
- Signpost intervals plan, transfer, verify, commit, gc and eviction (R-OBS-1); a background attempt's `transfer`
  interval is named `background attempt <n>` (`Sources/ZTronAssetTransport/Background/BackgroundSupport.swift:690`).

**What it does not expose:** the status, headers or `Content-Range` a transfer received; which OS tasks the background
coordinator re-attached, adopted or cancelled at launch (visible only through requests at the origin and job counts);
priority writes; the order of delegate callbacks; why a lane was gated (visible only through the conditions events and
the queued and running counts). A test that needs one of these names a breakpoint (a Debug build; a log action with
automatic continue). An attached debugger changes how the app is suspended (Apple's guidance; confirm in the current
documentation), so a background test attaches only through the scheme's "Wait for the executable to be launched"
option, and only where it says so. A logging patch to a local copy of the package, for an unattended run, is the
orchestrator's decision, and its diff goes with the results.

**Outside the kit:**

- Console.app on the Mac with the iPhone selected, filtered to subsystem `com.ztron.assetkit` (categories `store`,
  `sync`, `transport`, `apple`; R-OBS-1), info messages included; `OSLogSink` logs with privacy `.public`
  (`docs/DECISIONS.md:612`). Messages from the system's `nsurlsessiond` are evidence only; their content is not
  documented.
- Instruments: the os_signpost instrument for the kit's intervals; Allocations, Time Profiler, Hangs and System
  Trace; a network template for DT-NET-04 (confirm the template names in the installed Xcode).
- Conditions: Xcode's Devices window, Device Conditions (network link profiles, thermal state); Settings for Airplane
  Mode, Wi-Fi, cellular data, Low Data Mode and Low Power Mode.
- Background tests launch the app from the Home Screen, not from Xcode.

### 3.5 What each run records

Test id; date; device model; iOS build; probe-app build and the package commit; the configuration as
`diagnosticReport()` shows it; the steps as run; observations with times; the probe log and the origin's access-log
excerpt; pass, fail or not run; no secret in anything recorded.

## 4. Background session re-attachment (SPEC §8)

Common setup: `HTTPSourceConfiguration.background = .enabled(BackgroundTransferOptions(namespace: "probe",
discretionary: false))`, so the session identifier is `com.ztron.assetkit.bg.probe.v1`
(`Sources/ZTronAssetModel/Policy/RemoteConfiguration.swift:53`) and the system does not defer the transfers
(`discretionary` defaults to `true`, `:65`; one DT-BG-01 run uses the default and records when the system ran them);
the hook forwarded (§3.2); a catalog of three to five large checksummed files; the app launched from the Home Screen.

### DT-BG-01 · Relaunch re-attachment after the process ends

- **Requirements:** R-NET-3, R-INT-2, R-STO-3, R-CLN-3.
- **Why a device:** relaunch and re-attachment happen only with `nsurlsessiond` and the live driver (§2); §5 row :287;
  S3-B-050; ARCHITECTURE §14 (`docs/ARCHITECTURE.md:981`).
- **Steps:** (1) Fresh install; `sync(.force)`. (2) Once the origin log shows the downloads started, press Exit.
  (3) Wait until the origin log shows the files served, or 10 minutes. (4) Launch from the Home Screen; let the launch
  run settle. (5) Record `storageReport()`, `metrics()` and `diagnosticReport()`; run
  `performMaintenance(timeBudget: 30)`; record `storageReport()` again. (6) Repeat with Exit when the files are half
  downloaded, and Airplane Mode on for 2 minutes before the launch. (7) Repeat steps 1-5 with `discretionary` at its
  default.
- **Observe:** requests per file at the origin (a re-attached or adopted transfer makes no new request; one the kit
  cancelled at launch is requested again); `transferRequests` and `bytesDownloaded` after the launch; the jobs by
  state at launch and after settling; the probe log's `background attempt` intervals; `stagingBytes` before and after
  maintenance; for step 7, how long the system took to run the transfers.
- **Pass:** every asset present and hash-verified; no file served whole twice unless the probe log shows a failure
  with its class; `stagingBytes` 0 after maintenance (R-CLN-3); no crash and no integrity failure
  (`integrityFailures` 0).

### DT-BG-02 · The background-events hook end to end

- **Requirements:** R-NET-3.
- **Why a device:** UIKit never calls the hook on the host; the facade test calls `handleBackgroundEvents` directly
  (S3-B-099). Whether UIKit hands a second handler for one identifier while the first waits is device-only (§5 row
  :295; S3-CONC-02, S3D-2; ADR-057, `docs/DECISIONS.md:673`).
- **Steps:** (1) `sync(.force)`; press Home (do not Exit) and lock the device until the origin log shows the files
  served. (2) Unlock, open the app, read the probe log. (3) Repeat with two syncs whose transfers finish minutes
  apart, so that the system may wake the app twice.
- **Observe:** each hook call (identifier, time, return value); when the kit calls each handler, against the
  `background attempt` and `commit` intervals of the same wake; whether two calls overlap for one identifier.
- **Pass:** the hook returns `true` for `com.ztron.assetkit.bg.probe.v1` and `false` for any other identifier; each
  handler is called exactly once, after its wake's events are staged (`README.md:295-297`); overlapping handlers are
  completed oldest first (S3D-2; `BackgroundSupport.swift:811-814`); every asset published.

### DT-BG-03 · A hook attested but not wired (R-NET-3's run-time half)

- **Requirements:** R-NET-3.
- **Why a device:** detecting an unwired hook was declined (CCR-G1, ruling L5-R5): an app can attest `.enabled`
  without forwarding the hook and nothing notices (S3-B-054; §5 row :287;
  `Tests/ZTronAssetKitTests/CompositionTests.swift:39-44`). What the system then does with the session's events exists
  only on a device.
- **Steps:** the probe build with the forwarding off; DT-BG-02 step 1; bring the app to the foreground; then Exit and
  launch it again.
- **Observe:** whether and when the system woke or launched the app (the probe log's launches and their state);
  requests per file at the origin; when the assets became available (`syncFinished`, `storageReport()`).
- **Pass:** no data lost or corrupted: every asset present and verified after the next foreground or launch; the delay
  is recorded. A failure is evidence for the owner; it does not by itself reverse L5-R5.

### DT-BG-04 · Resume data end to end, and stale resume data

- **Requirements:** R-NET-8, R-INT-2.
- **Why a device:** whether the OS answers `downloadTask(withResumeData:)` with a 206 carrying `Content-Range` and
  moves the whole body, and which errors stale resume data gives (designed for −1002, 416 and a 206 without range),
  is device-only (§5 row :284; S3-B-049). The live driver's resume-data use
  (`Sources/ZTronAssetTransport/BackgroundSessionBackend.swift:58-60`) has no test: Stage 2's mutant ME there still
  survives (`docs/MUTATION-PROBES.md` §6.3).
- **Setup:** `SyncTuning.maxConcurrentTransfers = 1` with `preemptLowerLanes` at its default `true`; with one slot no
  interactive slot is reserved (`Sources/ZTronAssetModel/Policy/SyncTuning.swift:105-114`), so a user request pauses
  the running bulk transfer (`preemptForUser`, `Sources/ZTronAssetSync/Engine/EngineDispatch.swift:620-640`), and the
  coordinator keeps the transfer's resume data for its next attempt (`BackgroundSupport.swift:294-300`, `:534-542`).
- **Steps:** (1) `sync(.force)` with one 200 MB file. (2) At about 40 % (bytes served in the origin log),
  `resolve(_:)` a small asset; `metrics().preemptions` grows. (3) Let the small asset finish; the bulk transfer
  continues. (4) Stale case: repeat; while the bulk transfer is paused, replace the file on the origin with different
  bytes of the same size, the manifest unchanged; afterwards restore the original file.
- **Observe:** the continuation's request at the origin (its `Range` and `If-Range`, its status, the bytes served);
  the probe log's `background attempt` intervals for the file; for the stale case, the `sync` failure lines,
  `metrics().failures` and `integrityFailures`, and the recent errors. The status and `Content-Range` the OS hands the
  kit are not logged: a breakpoint at `SessionDelegate.finishDownload`
  (`Sources/ZTronAssetTransport/Session/SessionDelegate+Downloads.swift:34`) shows them, with the debugger attached
  and the app in the foreground (the session's transfer runs in `nsurlsessiond` either way).
- **Pass:** the asset ends present and verified, and no unverified byte is published (R-INT-2). The record says
  whether the continuation moved the whole body (one ranged request answered 206, only the remainder served), which
  confirms the designed path, or fell back to a fresh download after a `truncated` size check (§5 row :284), the
  designed fallback and evidence for the orchestrator. Stale case: the resumed file fails verification, is never
  published (R-NET-8: resumed bytes are never trusted without the final hash), and succeeds once the original file is
  back.

### DT-BG-05 · A fresh background download finished with a ranged 206 (due before background transfers ship)

- **Requirements:** R-NET-8, R-NET-6.
- **Why a device:** whether `nsurlsessiond` ever finishes a fresh download (not made from resume data) with a ranged
  206 after an internal retry (D-19.1, D-20.3) cannot be produced on the host (§5 row :285; S3-B-046, rank 16 in the
  backlog).
- **Steps** (§5 row :285): a large checksummed download; connectivity interrupted mid-way (Airplane Mode, or a Device
  Conditions profile with 100 % loss) and restored, several times per run; at least 10 runs. The app may stay in the
  foreground with the debugger attached.
- **Observe:** at the origin, any ranged request the system makes on its own after an interruption, and its status;
  the final status and `Content-Range` that `finishDownload` receives (breakpoint at
  `SessionDelegate+Downloads.swift:34`); the outcome (a verified asset, or a `sync` failure line and a recent error).
- **Pass:** every run ends with a verified asset. If a ranged 206 reaches `finishDownload`, today's code fails the
  attempt `unexpectedStatus(206)` and adopts nothing (§5 row :285): record it and send a D-4 deviation to the
  orchestrator. Background transfers do not ship before this test has run.

### DT-BG-06 · The task tag across a relaunch; the start argument and the overload

- **Requirements:** R-NET-3, R-NET-8.
- **Why a device:** whether the OS keeps `taskDescription` (the `ztak1` tag with its resume flag) on a task created
  from resume data across a relaunch (D-19.2), and whether the live driver passes the right `forStart` argument and
  overload (D-20.1, where a mutant passes every host test), are device-only (§5 row :286; S3-B-047).
- **Steps:** DT-BG-04 steps 1-3, but press Exit while the continued transfer runs; launch from the Home Screen.
- **Observe:** whether the file is requested again whole at the origin after the launch. A task whose tag is foreign
  or cannot be decoded is cancelled (`BackgroundSupport.swift:57`), so a lost tag shows as a new whole download.
  To read the tag itself (§5 row :286), a second run attaches through "Wait for the executable to be launched" with a
  breakpoint at `BackgroundSessionBackend.swift:48`, where the launch listing decodes each task's
  `taskDescription`.
- **Pass:** the task created from resume data is re-attached and completes, with no second whole download.

### DT-BG-07 · The live driver's callback order and timing

- **Requirements:** R-NET-3.
- **Why a device:** the order of `didFinishDownloadingTo`, `didCompleteWithError` and `cancelByProducingResumeData`'s
  completion, the timing of `urlSessionDidFinishEvents`, `finishTasksAndInvalidate`, and task creation against
  `invalidate()` are proven only against a fake driver (§5 row :287; S3-B-050).
- **Steps:** the kit logs none of these, so this test uses breakpoints with a log action and automatic continue at
  `SessionDelegate+Downloads.swift:11` (`didFinishDownloadingTo`), `SessionDelegate+DataTasks.swift:113`
  (`didCompleteWithError`), `SessionDelegate+Downloads.swift:27` (`urlSessionDidFinishEvents`),
  `BackgroundSessionBackend.swift:75` (the resume-data cancel), `:60` (task creation) and `:87` (`invalidate`).
  (a) With the app in the foreground: two background downloads, one preemption (DT-BG-04's setup), one `shutdown()`
  during a transfer. (b) One relaunch attached through "Wait for the executable to be launched".
- **Observe:** for each transfer, the order and times of the callbacks; any task created after `invalidate`.
- **Pass:** no orphaned task, no file finished but not adopted, and no callback the driver ignores; an order that
  differs from the fake driver's is recorded with its log.

### DT-BG-08 · Priority writes reach the OS task

- **Requirements:** R-NET-10, R-SYN-3.
- **Why a device:** whether a background `URLSessionTask` applies the last `priority` written, and in which order two
  writes land when each follows its own `allTasks` listing (S3D-1's newest-request serial and rewrite loop; the write
  at `BackgroundSessionBackend.swift:79-83`, the listing at `:90-92`), is device-only (§5 row :296). So is a
  rewrite to an old task identifier after the same attempt's name was created anew. Only a reading of the
  coverage-excluded live driver covers it: the driver looks the identifier up among the session's tasks and writes
  nothing when it is gone (`:90-92`; the rewrite loop, `BackgroundSupport.swift:477-484`;
  `docs/adr-drafts/s3d.md:141-142`; `docs/DECISIONS.md:673`).
- **Steps:** two large background downloads at bulk; promote one with `resolve(_:)` on its id and cancel that task
  within a second, so that the transfer returns to bulk; repeat 10 times, alternating the transfer. The app stays in
  the foreground, so an attached debugger does not change what the test needs.
- **Observe:** each write, with a breakpoint (log action, automatic continue) at `BackgroundSessionBackend.swift:81`
  printing the task identifier and the priority; each write request, with a second one at `:80` printing
  `taskIdentifier`; which transfer finishes first (origin log, `background attempt` intervals). A request logged at
  `:80` with no write at `:81` found no task with that identifier.
- **Pass:** for each task, the last write matches the newest request in every run. The finish order is evidence only:
  the OS treats priority as a hint (§5 row :296). A request that finds no task, if one occurs, writes nothing and
  nothing fails; it is recorded with its time and identifier. A rewrite after the name was created anew cannot be
  staged on purpose here (§14).

### DT-BG-09 · `shutdown()` with background downloads in flight

- **Requirements:** R-SYN-15, R-NET-3.
- **Why a device:** an explicit `shutdown()` cancels background downloads in flight as a best effort, and a killed or
  suspended app cancels nothing (`README.md:301-304`). D-10 stays NEEDS-HUMAN-REVIEW with a nuance: the engine's
  cancel can queue behind a priority change and reach no OS task (`PROBE shutdownCancelQueuedBehindPriority
  cancellations=[] priorityChanges=[]`; ADR-050's amendment, `docs/DECISIONS.md:384`). What the OS does with a cancel
  that does not land exists only on a device.
- **Steps:** start background downloads; `shutdown()`; wait 5 minutes; Exit; launch.
- **Observe:** the bytes the origin served for each request (a cancelled download shows fewer bytes than the file);
  what the next launch requests and adopts.
- **Pass:** after the launch every asset is present and verified, or missing and re-downloadable; none corrupt.
  Downloads that ran to the end after the shutdown are recorded as the best-effort case, evidence for D-10's review.

## 5. Apple-hosted packs through TestFlight (SPEC §8)

Common setup: the probe app on iOS 26 or later with `RemoteConfiguration(http:appleHosted:awsOnly:)` naming an
`AppleTierConfiguration` (`RemoteConfiguration.swift:128`, `:163`); the downloader extension, the Info.plist keys, the
App Group and the packs (essential, prefetch and on demand) set up as Apple's BackgroundAssets documentation says
(`README.md:321-329`: this repository names none of the keys, because none was verified); the catalog at
`ZTronCatalog/catalog.json` in the essential pack (the defaults, `RemoteConfiguration.swift:139-142`); the build
uploaded to App Store Connect and installed through TestFlight. The tier's live backend is device-only (§2).

### DT-APL-01 · The TestFlight build and its setup

- **Requirements:** R-APL-1, R-APL-5.
- **Why a device:** the Apple-hosting setup that README and MIGRATION step 3 ask of the app is not verified beyond
  APPLE-API-VERIFICATION §1.7, and nothing ran on a device (S3-B-127).
- **Steps:** install from TestFlight; launch online; read the probe log and `diagnosticReport()`. A second build sets
  `awsOnly`, with `http` naming the test origin.
- **Observe:** which tier serves: the `apple` line `catalog read from pack <id>: <n> bytes`
  (`Sources/ZTronAssetAppleHosted/AppleHostedRemoteSource.swift:86`), or a manifest request at the test origin; the
  configuration keys (`remote.awsOnly`, `remote.appleHosted.*`; `DiagnosticReportBuilder.swift:63`, `:86-90`); errors
  in the `apple` category; the extension's own messages in Console.
- **Pass:** the Apple-hosted tier serves the catalog; with `awsOnly` the CloudFront tier serves it (R-APL-5).

### DT-APL-02 · The essential catalog pack before the first launch

- **Requirements:** R-APL-4.
- **Why a device:** whether essential packs are on disk before the first launch of an Apple-hosted app needs
  TestFlight (§5 row :291).
- **Steps:** install from TestFlight; turn Airplane Mode on before the first launch; launch.
- **Observe:** the `apple` lines `catalog read from pack …` or `catalog pack <id> is not installed; making it
  available` (`Sources/ZTronAssetAppleHosted/AppleCatalogReader.swift:31`); `availability(scope:)`
  (`AssetClient.swift:210`).
- **Pass:** the catalog loads offline from the essential pack; or, if the pack is not on disk yet, the client reports
  it as a typed error and loads it once online, with no crash and no false "synced" state.

### DT-APL-03 · An on-demand pack: staged, hashed, adopted and released

- **Requirements:** R-APL-3, R-CLN-10, R-INT-2, R-CLN-9.
- **Why a device:** `LiveAssetPackBackend.installedBytes` reports the pack's download size, because the 26.0 surface
  has no installed size, and that feeds `StorageReport.sourceCopyBytes` (§5 row :281; S3-B-060).
- **Steps:** with `PackRetention.releaseAfterAdoption` (the default), resolve an asset of an on-demand pack; read
  `storageReport()` before the request, after the adoption and after the release; repeat with `.keepPacks`.
- **Observe:** `sourceCopyBytes`, against the pack's uncompressed size from its build input; the `apple` line
  `released pack <id>: every catalog entry in it is adopted or excluded` (`AppleHostedRemoteSource.swift:143`).
- **Pass:** each asset is staged, hashed and adopted (R-INT-2); with `releaseAfterAdoption` the pack is released once
  every entry it holds is adopted or excluded (`README.md:313-315`), at most once per catalog generation (R-CLN-10);
  the difference between `sourceCopyBytes` and the pack's size is recorded.

### DT-APL-04 · Cloning from a pack under the sandbox (optional)

- **Requirements:** R-APL-3.
- **Why a device:** the kit does not clone today: it streams each file from the pack's descriptor into staging
  (`docs/APPLE-API-VERIFICATION.md:265`). An `fclonefileat` clone is an optional optimisation, not built, and whether
  the sandbox allows cloning from the OS-managed pack store is device-only (§5 row :288; `:117`).
- **Steps:** only if that optimisation is taken up: in the probe app, open a pack file's descriptor as
  APPLE-API-VERIFICATION §1 records and call `fclonefileat` into a directory of the app's container (`:117`).
- **Pass:** the return value and `errno` recorded; they decide whether the optimisation is feasible.

### DT-APL-05 · Cancellation promptness and abandoned pack flights

- **Requirements:** R-APL-1, R-SYN-4.
- **Why a device:** whether `ensureLocalAvailability(of:)`, `statusUpdates(forAssetPackWithID:)` and
  `checkForUpdates()` return promptly when cancelled, and how many abandoned flights accumulate per swipe while one
  pack downloads (E-3, E-6), are device-only (§5 row :282; S3-B-061).
- **Steps:** while a large on-demand pack downloads, start and cancel a `resolve(_:)` of one of its assets 20 times in
  20 seconds.
- **Observe:** how long each cancelled call takes to return (the probe app times its own tasks); memory (Xcode's
  memory gauge); the flights themselves are not exposed: a breakpoint in
  `Sources/ZTronAssetAppleHosted/PackAvailabilityCoordinator.swift` (its state, `:48-50`) shows them.
- **Pass:** cancelled calls return without waiting for the download; flights do not grow without bound; the pack
  finishes and its assets are adopted once.

### DT-APL-06 · Networks, cellular data and Low Data Mode for pack downloads

- **Requirements:** R-SYN-7, R-APL-1.
- **Why a device:** which networks BackgroundAssets uses for on-demand downloads and update checks, and whether the
  app's cellular-data setting constrains them; the tier cannot honour `NetworkAccess`, and the engine gates Apple-tier
  transfers on its own conditions, tested over fakes only (§5 row :283; E-17; S3-B-060).
- **Steps:** on cellular only: (a) the app's cellular data on; (b) off (Settings, Cellular, the app); (c) Low Data
  Mode on. Each time, `resolve(_:)` an on-demand pack asset and run `sync(.force)` at bulk.
- **Observe:** whether each download proceeds; the conditions events; the queued and running counts.
- **Pass:** bulk pack work follows `NetworkPolicy` (`bulkOnExpensive`, `bulkOnConstrained`) and a user request
  follows `userInitiatedOverridesPolicy` (`Sources/ZTronAssetModel/Policy/NetworkPolicy.swift:3-12`); anything the
  system does beyond the engine's gate is recorded.

### DT-APL-07 · A removed pack: downloaded again by the system?

- **Requirements:** R-APL-3, R-CLN-10.
- **Why a device:** whether a removed essential or prefetch pack is downloaded again automatically (next app update,
  `checkForUpdates`, background poll) is not documented (§5 row :279).
- **Steps:** after DT-APL-03's release, read the probe log daily for a week, through one TestFlight update.
- **Observe:** the `apple` lines `update check: <n> packs updating, <m> removed`
  (`Sources/ZTronAssetAppleHosted/AppleSourceState.swift:177`) and `released pack …`; the app's storage in Settings.
- **Pass:** behaviour recorded; the kit never releases one pack twice in a catalog generation and never loses an
  adopted asset.

### DT-APL-08 · An in-place `url(for:)` across a pack update (optional)

- **Requirements:** R-APL-3.
- **Why a device:** whether the bytes at an in-place `url(for:)` path stay stable within a process when the system
  updates the pack mid-session needs a device and a server-side update (§5 row :289). It matters only if in-place
  serving, R-APL-3's alternative, is reconsidered: the kit adopts and releases (`docs/APPLE-API-VERIFICATION.md:265`).
- **Steps:** only in that case: publish a new pack version while the app reads a file of the old one in place.
- **Pass:** behaviour recorded.

### DT-APL-09 · A pack download on a full disk

- **Requirements:** R-SYN-11, R-NET-6, R-APL-1.
- **Why a device:** which error a pack download throws on a full disk, and that it reaches the engine as
  `insufficientSpace`: the tier maps `NSPOSIXErrorDomain` ENOSPC and `NSCocoaErrorDomain` 640 to
  `insufficientSpace(requiredBytes: nil)` (§5 row :280; E-5; S3-B-060).
- **Steps:** fill the device with the Filler until less than the pack's size is free; resolve an asset of the pack.
- **Observe:** the `apple` line `attempt <n>: pack <id> unavailable: <error>`, whose text describes the error the
  system threw (`Sources/ZTronAssetAppleHosted/PackTransfer.swift:211`), or `staging failed: <reason>` (`:252`); the
  `sync` failure line's class; `metrics().failures`.
- **Pass:** the request fails as `insufficientSpace`, never as transient or integrity; after the Filler is deleted the
  request succeeds.

### DT-APL-10 · A pack removal that fails (observe only)

- **Requirements:** R-CLN-10.
- **Why a device:** a removal that fails and leaves the pack installed (E-12) exists only with real packs (S3-B-061).
- **Steps:** none of its own; watch DT-APL-03's and DT-APL-07's probe logs for `releasing pack <id> failed: <reason>`
  (`AppleHostedRemoteSource.swift:138`).
- **Pass:** a failed removal is logged, a later release is attempted, and no asset is lost.

## 6. Low storage (SPEC §8)

Common setup: the probe app's Filler (§3.2). Free space is read in Settings and in `storageReport()`'s
`freeBytesImportant` and `freeBytesOpportunistic` (`Reports.swift:101`, `:103`). Delete the Filler after each test.

### DT-STO-01 · A sync that does not fit

- **Requirements:** R-SYN-11, R-CLN-4.
- **Why a device:** the fakes inject ENOSPC; a full APFS volume, its capacity readings and the system's own reaction
  to low storage exist only on a device.
- **Steps:** (1) Sync the small catalog. (2) Publish a manifest that adds about 1 GB. (3) Fill until free space is
  below that, with `StoragePolicy.evictionPermitted` true (the default,
  `Sources/ZTronAssetModel/Policy/StoragePolicy.swift:95`), then false. (4) `sync(.force)`. (5) Delete the Filler and
  sync again.
- **Observe:** the outcome; `metrics()` `evictions`, `evictedBytes` and `failures`; the `store` lines on quota
  eviction (`Sources/ZTronAssetStorage/Eviction/QuotaEviction.swift:148`, `:154`); `stagingBytes`.
- **Pass:** with eviction permitted, the sync evicts within the policy (never an essential, pinned, leased or
  recently accessed asset, R-CLN-4) or fails typed; without it, the sync fails with
  `insufficientSpace(required:available:)` and no partial side effects (R-SYN-11), and no staged bytes remain after
  maintenance; step 5 succeeds.

### DT-STO-02 · ENOSPC with a pending reclaim: attempt churn

- **Requirements:** R-SYN-11, R-SYN-5.
- **Why a device:** an ENOSPC with a pending reclaim waits `awaitingSpace`, counted against the retry budget with no
  timed backoff, so attempts can run back to back (PROBE-C6R-1: 2 starts in 0.0 s); whether that churns on a real
  volume needs a device test (S3-B-066, an accepted deviation; ADR-057, `docs/DECISIONS.md:616`, `:659`).
- **Steps:** the free-space check refuses work that does not fit at the start (R-SYN-11), so the ENOSPC has to come
  mid-transfer: (1) fill until free space is just above the reserve plus two large assets; (2) purge a set of assets,
  so that their bytes wait for the deletion grace (`StoragePolicy.deletionGrace`, default 10 s,
  `StoragePolicy.swift:86`); (3) at once `resolve(_:)` the two large assets; (4) while they download, grow the Filler
  until writes fail.
- **Observe:** attempt starts per asset and their times (the probe log's `transfer` intervals); the `sync` failure
  lines; `metrics()` `retries` and `failures`.
- **Pass:** attempts per asset stay within the retry budget per run, and the assets succeed once the reclaim lands and
  the Filler is deleted. Back-to-back attempts are recorded with their count and spacing, for F-27(c)'s backoff
  question (S3-B-066).

### DT-STO-03 · Opportunistic and important capacity under pressure

- **Requirements:** R-SYN-11, R-CLN-9.
- **Why a device:** whether iOS reports `volumeAvailableCapacityForOpportunisticUsage` above
  `volumeAvailableCapacityForImportantUsage`, the precondition of PROBE-C6-LANEGAIN;
  `Sources/ZTronAssetStorage/FileSystem/LiveFileSystem.swift:93-109` reads both keys with no ordering clamp (§5 row
  :293).
- **Steps:** read `storageReport()` at about 20 GB, 5 GB, 1 GB and 200 MB free.
- **Pass:** values recorded. Opportunistic above important is recorded for the orchestrator; the engine treats the
  two readings as unordered, so it is evidence, not a failure.

### DT-STO-04 · The OS purges a `.caches` root

- **Requirements:** R-CLN-7, R-STO-2, R-CAR-8.
- **Why a device:** a real `rootVanished` (iOS purging a Caches root), the reopen there and the root check's cost are
  device-only (S3-B-098). S3-B-094's limits are accepted deviations to watch here: a replaced root no commit has
  detected is used until a qualifying failure or a commit, a root check whose stat fails records nothing, and
  `withAsset` can lease from a root that vanished after its read (`docs/DECISIONS.md:620`).
- **Steps:** `StorageLocation.caches`; sync the small catalog. (a) Fill to within about 1 GB of full with the Filler,
  send the probe app to the background, then record 4K video in the Camera app until iOS reports that storage is
  full; open the probe app. (b) The same with the app ended by Exit first, then launched. Apple's documentation has
  said that the system does not purge Caches while the app runs (confirm in the current documentation), so a purge
  with the app in the foreground is not expected; the system decides whether to purge at all.
- **Observe:** whether the root vanished; the `store` lines `root check failed: storageUnavailable(rootVanished)…`
  (`Sources/ZTronAssetStorage/Store/AssetStore.swift:134`) and `OS purge detected: <n> blobs missing; sync due`
  (`Sources/ZTronAssetStorage/Store/AssetStore+Open.swift:133`); a replacement's `clientStarted` after a reopen
  (`AssetEvent.swift:120-122`); `assetRemoved(…, .vanished)`; calls that failed meanwhile.
- **Pass:** no crash and no false "synced" state; after a purge the stamp is reset and assets heal by re-sync or on
  demand (R-CLN-7); a `withAsset` body that was running ends with its file or a typed error. If no purge happens, the
  test is recorded as not reached.

### DT-STO-05 · File protection, backup exclusion and work after the first unlock

- **Requirements:** R-STO-8.
- **Why a device:** R-STO-8 asks for a device check here; the host verifies only the fake's attribute recording.
  File protection on a device is part of S3-B-021.
- **Steps:** (1) From the probe app, read the store root's `FileAttributeKey.protectionKey` and its
  `isExcludedFromBackup` resource value, as `LiveFileSystem.storeAttributes(at:)` reads them
  (`LiveFileSystem.swift:115-126`); the root is `Application Support/ZTronAssetKit/v1/` by default
  (`StoragePolicy.swift:3-6`); read a blob's values too. (2) Start a background download, lock the device, wait for
  the origin to serve it, unlock. (3, optional) Restart the device and, before the first unlock, let a background wake
  happen if one comes.
- **Observe:** the values; whether (2) published while locked; what the probe log holds from before the first unlock.
- **Pass:** the root has protection `completeUntilFirstUserAuthentication` and is excluded from backup; (2) publishes
  while locked after the first unlock; (3) defers or fails typed without corrupting the store. The blob's values are
  recorded.

### DT-STO-06 · Process kills and forced restarts during sync and commit

- **Requirements:** R-STO-4, R-STO-5, R-INT-4.
- **Why a device:** the semantics and cost of `F_BARRIERFSYNC` and `F_FULLFSYNC` (S3-B-021); a `rename(2)` that takes
  effect and reports failure, `lstat`/`pread` I/O errors, and how long a killed process's rename stays undoable (B-36,
  S3-B-022); and the difference between an ordered and a durable commit, which the fake file system cannot show (OI-2,
  `docs/ARCHITECTURE.md:981`) are modelled only by the fake.
- **Steps:** during a large-catalog sync: (a) Exit at 10 points spread over the run; (b) force-restart the device (the
  closest a tester gets to a power loss) at 5 points; (c) run the allocation control until the system ends the app,
  once. After each, launch and run `performMaintenance(timeBudget: 30)`.
- **Observe:** the `store` lines at launch (an index file that could not be read, a failed launch commit, an OS purge
  detected: `AssetStore+Open.swift:115`, `:122`, `:133`) and from deep verification
  (`Sources/ZTronAssetStorage/Integrity/DeepVerification.swift:90`); the lifecycle in `diagnosticReport()`; the
  maintenance report; the `commit` intervals.
- **Pass:** every reopen succeeds; no blob that a committed generation references is lost, and none is published
  unverified (I-1 to I-5, as far as reports show them); deep verification finds no corrupt blob. `LiveFileSystem`
  errors the fake cannot produce are recorded if any appear.

### DT-STO-07 · Deep verification against a same-size replacement (optional)

- **Requirements:** R-INT-4, R-CLN-8.
- **Why a device:** deep verification's incarnation check against a real rename-over on APFS: a volume that reuses
  inode numbers at once could hide a same-size replacement, while the fake gives every new file a new inode
  (S3-B-037).
- **Steps:** download the app container (Xcode's Devices window), replace one blob with different bytes of the same
  size, replace the container, launch, run `performMaintenance(timeBudget: 30)`.
- **Pass:** the `store` line `deep verification found a corrupt blob; it is quarantined` (`DeepVerification.swift:90`)
  and `assetRemoved(…, .quarantined)` appear; the asset is downloaded again (R-INT-4, R-CLN-8).

## 7. Memory warnings (SPEC §8)

Common setup: the probe app's test cache registered with `register(_:)`; memory warnings raised by the allocation
control (the simulator's "Simulate Memory Warning" is not a device's memory pressure).

### DT-MEM-01 · `.live()` alone: a memory warning purges nothing

- **Requirements:** R-CLN-11.
- **Why a device:** `AssetEnvironment.live()` supplies no memory-pressure source (`memoryPressure` is optional with
  default `nil`, `AssetEnvironment.swift:28`, `:47`), so on a device a memory warning purges nothing unless the app
  supplies a UIKit source: an accepted deviation (S3-B-009; ADR-057, `docs/DECISIONS.md:602`).
- **Steps:** without an app source, allocate until UIKit posts a memory warning (the probe app logs it); continue to a
  second warning.
- **Observe:** calls to the test cache's `purge(level:)`; `memoryPressureObserverActive` in `diagnosticReport()`
  (`DiagnosticReportBuilder.swift:131`).
- **Pass:** no purge call, and the observer reported inactive, as documented. Anything else is a defect.

### DT-MEM-02 · An app-supplied UIKit source

- **Requirements:** R-CLN-11, R-SYN-15.
- **Why a device:** the UIKit source lives outside the module and is exercised on the host only through the fake
  memory-pressure source (`docs/ARCHITECTURE.md:976`).
- **Setup:** a `MemoryPressureSource` whose `pressureEvents()` (`EnvironmentSeams.swift:115`) yields `.warning` on
  UIKit's memory-warning notification.
- **Steps:** as DT-MEM-01; then `shutdown()` and raise one more warning.
- **Observe:** each `purge(level:)` call, with its level, thread and time; any store change or `assetRemoved` event
  after a warning.
- **Pass:** each registered cache is purged once per warning, on the main actor (`EnvironmentSeams.swift:104`); none
  after `shutdown()`; a store change after a warning is recorded (none is expected: R-CLN-11 is about in-memory
  caches).

### DT-MEM-03 · Manifest decoding: memory and time on a device

- **Requirements:** R-MAN-3, P-3.
- **Why a device:** R-MAN-3's allocation figures (3.75× the payload in the build pass, 2.3× in the survey pass,
  against its 4× bound) were measured on macOS 27 and the iOS 27 simulator only; device allocators are unverified
  (S3-B-004; ADR-057, `docs/DECISIONS.md:644`, `:669`).
- **Steps:** Release build; serve a 32 MiB manifest; force a manifest fetch; measure with Allocations; three times.
  Then the realistic manifest of P-3 (about 3.3 MB).
- **Observe:** peak memory above the baseline; the decode's duration (Time Profiler).
- **Pass:** peak below 4× the payload and decoding within 1 s for 32 MiB (R-MAN-3); P-3's figure recorded beside the
  host's.

## 8. Network, power and thermal

### DT-NET-01 · Real path transitions and retries without polling

- **Requirements:** R-NET-9, R-SYN-13.
- **Why a device:** real `NWPathMonitor` transitions (S3-B-051) exist only on a device; the host uses a fake
  conditions source.
- **Steps:** during a sync: Wi-Fi off with cellular on; Airplane Mode on for 2 minutes; Wi-Fi back. Repeat with the
  device locked.
- **Observe:** the conditions events (satisfied, expensive, constrained; coalesced newest-wins); the `sync` failure
  lines of class `offline` or `transient` and their times; `transfer` intervals.
- **Pass:** an asset that failed as `offline` (disposition `.whenOnline`) gets no new `transfer` interval until the
  path is satisfied again (no polling), and is then retried (R-SYN-13); the run completes.

### DT-NET-02 · `NWPathMonitor`'s first callback

- **Requirements:** R-NET-9.
- **Why a device:** when the first `pathUpdateHandler` callback arrives relative to user work, and a notification
  arriving between `start` and the first update (D-18.5); since S3-CONC-04 correctness does not depend on it, because
  a satisfied first reading counts as an edge (`Sources/ZTronAssetSync/Engine/EngineConditions.swift:101`) (§5 row
  :294; S3-B-051).
- **Steps:** cold-launch 10 times online and 10 times in Airplane Mode, issuing a `resolve(_:)` at once.
- **Observe:** the time from `clientStarted` to the first conditions event; the request's outcome.
- **Pass:** timing recorded; every online request succeeds; an offline request ends with `.offline` (disposition
  `.whenOnline`), and the same request succeeds once the path is satisfied.

### DT-NET-03 · Lane policy on expensive and constrained networks

- **Requirements:** R-SYN-7.
- **Why a device:** expensive and constrained paths, and Low Data Mode, come from the real path monitor.
- **Steps:** on cellular: `sync(.force)` and a prefetch window with `NetworkPolicy`'s defaults
  (`NetworkPolicy.swift:3-27`); then Low Data Mode on; then a `resolve(_:)` in each state.
- **Observe:** the conditions events; the queued and running counts per lane; `transfer` intervals.
- **Pass:** bulk and prefetch run or wait as `bulkOnExpensive`, `bulkOnConstrained`, `prefetchOnExpensive` and
  `prefetchOnConstrained` say; user requests run, since `userInitiatedOverridesPolicy` defaults to `true` (`:20`).

### DT-NET-04 · HTTP/2 connection reuse against CloudFront

- **Requirements:** R-NET-2, P-10.
- **Why a device:** P-10 is HTTP/1.1 keep-alive on loopback; HTTP/2 reuse against CloudFront is unverified
  (S3-B-051; `Sources/ZTronAssetTestSupport/LoopbackHTTPServer.swift:124`; `docs/ARCHITECTURE.md:981`).
- **Steps:** the owner's build against the production origin (§3.3); resolve 50 small assets; record with an
  Instruments network template.
- **Pass:** the foreground transfers share one HTTP/2 connection, or the few the system opens, not one per download;
  the key appears in nothing recorded.

### DT-PWR-01 · Low Power Mode and thermal states

- **Requirements:** R-SYN-7.
- **Why a device:** thermal state and Low Power Mode signals are device-only (`docs/DECISIONS.md:674`;
  `docs/ARCHITECTURE.md:981`).
- **Steps:** during a bulk sync with a prefetch window: Low Power Mode on, then off; Device Conditions thermal state
  fair, serious, critical, then back to nominal; a `resolve(_:)` at each step.
- **Observe:** the conditions events (Low Power Mode, thermal level); the queued and running counts per lane.
- **Pass:** with `PowerPolicy`'s defaults (`NetworkPolicy.swift:31-58`): bulk pauses in Low Power Mode and prefetch
  continues (`:32-35`); bulk and prefetch pause at `.serious` and resume only at `.fair` or below (`:36-39`); at
  `.critical`, new user-initiated dispatches are limited to `interactiveConcurrencyAtCritical`, and user work
  dispatched while the conditions were unknown is not trimmed (`:40-42`; S3F-7(b), `docs/DECISIONS.md:240`).

## 9. Performance on a device

Release builds; the device on mains power, cool, with no other app running. Every figure here is evidence, judged
against SPEC §6 only where §6 states a budget; the known misses (`docs/RESIDUAL-RISKS.md`) are not re-judged by a
device figure.

### DT-PERF-01 · The benchmark bundle on a device: a prerequisite

- **Requirements:** SPEC §6 (P-1 to P-14), C2.
- **Why a device:** P-8, P-9 and the C2 figures were measured on the macOS host only (S3-B-100; ADR-057,
  `docs/DECISIONS.md:646`, `:659`, `:674`).
- **Prerequisite (deduced from the code, not tried):** the cases that read `QualityBudgets` find
  `Scripts/quality-gates.json` through a `#filePath`-relative path
  (`Tests/ZTronAssetKitBenchmarks/QualityBudgets.swift:12-17`), and live-file-system tests use directories inside the
  repository (`docs/ARCHITECTURE.md:976`): a simulator process shares the host's file system, a device process does
  not. The C2 cases assert the literal `c2Budget` (`Tests/ZTronAssetKitBenchmarks/BenchSync.swift:129`) and may not
  need the file. Running the bundle on a device needs those inputs made reachable there, a change to `Tests/` for the
  orchestrator to decide; until then DT-PERF-02 to DT-PERF-05 measure through the probe app.
- **Pass:** once the bundle runs, each case's figure is recorded beside the host's; a red is reported with its
  figures, never re-judged.

### DT-PERF-02 · A purge's first turn at 10,000 ids, and S1's line

- **Requirements:** R-CLN-6, R-OBS-1, C2.
- **Why a device:** the six purge cases miss C2's 10 ms limit on the host (17.82-64.00 ms; `docs/DECISIONS.md:589`,
  `:626`); a device figure is unknown. The owner's re-open criterion is how often the misses happen in the field, and
  S1's `.info` line is the kit's only signal (`docs/DECISIONS.md:612`, `:625`).
- **Steps:** sync the large catalog; set up one prefetch window, then four (many ids each), and some waiting user
  requests, as in the bench shapes; `purge(.all)`, `purge(.evictable)` and `purge(.scope(…))`, three times each.
- **Observe:** each `long purge turn: <ms> ms, <jobs> jobs, <groups> groups` line in the probe log.
- **Pass:** figures recorded per shape. The real HTTP source's `originID` cost (UNCONFIRMED, 15-60 ms per 10,000
  gate reads; `docs/DECISIONS.md:632`) is part of these figures, unlike the benches'.

### DT-PERF-03 · Reclaiming 10,000 blobs on a device's APFS (P-13's stalls)

- **Requirements:** P-13, R-CLN-6, C2.
- **Why a device:** whether `unlink(2)` on a device stalls while the volume commits, as the host's APFS does, and how
  often, decides P-13's p99 (host: 7-13 stalls over 2 ms per 10,000 unlinks, maxima 4.4-6.6 ms, about every
  850-1,060 unlinks with the 256-way fan-out; S3B-12; §5 row :297; S3-B-021; `docs/DECISIONS.md:621`). S3-B-038's
  four items were measured on macOS over the fake file system only: C-22's actor holds, `apply`'s chunked eviction,
  a purge's wait for another reaper's deletion (a kernel-blocked unlink delays it) and the holders-scan prefilter's
  even-spread assumption; so were S3C-2's per-turn costs (`docs/DECISIONS.md:672`).
- **Steps:** sync the large catalog; `purge(.all)`; wait out the deletion grace (default 10 s,
  `StoragePolicy.swift:86`); `performMaintenance(timeBudget: 60)`; three times. Record with System Trace.
- **Observe:**
  - Total reclaim time (the `gc` and `eviction` intervals in the probe log); `unlink` durations in System Trace, and
    how many exceed 2 ms and 5 ms per 10,000.
  - The store's actor during the purge and the maintenance, in the same trace and in a second pass with Time
    Profiler: the longest interval a thread runs `AssetStore` frames without blocking, and any `unlink` stall inside
    one. Each `purge(_:)` call's time to return (the probe app times its own calls), and any `unlink` stall on
    another thread while it waits. The kit times no store turn, so these are estimates, not C2 figures.
  - Not observable here: the prefilter's spread. It changes only how long a holders scan takes inside a turn,
    since a clear bit proves a blob is not wanted whatever the spread (`HolderScan.swift:69-70`).
  - The bench bundle on the device (DT-PERF-01) gives the figures this test cannot: P-13's own, the deletion units'
    p99, and a device run of S3B-12's probe (§5 row :297); and the C2 figures of C-22's holds, `apply`'s chunked
    eviction and S3C-2's shared-blob turns, in `CleanupBenchmarks`
    (`Tests/ZTronAssetKitBenchmarks/BenchCleanup.swift:18`; Stage 5's host figures at
    `.worktrees/merge-check/.verify-logs/benchmarks.log:28-54`, in the main checkout). Those cases run over the fake
    file system (`BenchCleanup.swift:12-15`), so they measure the device's CPU, not its APFS.
- **Pass:** recorded: the total against `gc_total_s_max` (2 s); the stall rate and maxima beside the host's; the
  longest store interval and the purges' waits as evidence. The per-unit p99 is judged by the owner's ruling only
  when the bundle runs (`docs/DECISIONS.md:380`).

### DT-PERF-04 · The main thread, the prefetch window and publications at 10,000

- **Requirements:** P-8, R-STO-7, R-CAR-3.
- **Why a device:** P-8 and P-9 on a device (S3-B-100); S3B-13's user-initiated publications grow quadratically on
  the host (10k/5k ratio 2.71-2.86, about 0.5-1 ms each at 10,000), deferred to Stage 5 with the owner's P-8 run
  (`docs/DECISIONS.md:621`, `:647`).
- **Steps:** with the large catalog and a bulk sync running, step a `PrefetchWindowController`
  (`Sources/ZTronAssetKit/Prefetch/Prefetch.swift:126`) through 200 positions with `update(ids:current:)` (`:146`) and
  the default radius, calling `lookup(_:)` (`AssetClient.swift:191`) at each; then `resolve(_:)` 1,000 assets one
  after another.
- **Observe:** main-thread time and hangs (Time Profiler, Hangs); the probe app's timing of each main-actor call it
  makes; the time from each `resolve(_:)` to its return, and the `commit` intervals around them.
- **Pass:** no file-system call or hash from the kit on the main thread (R-STO-7) and every UI-facing call within
  `ui_call_ms_max` (P-8); resolve times recorded for S3B-13's decision (S3B-13's own measurement needs the bundle).

### DT-PERF-05 · The follow barrier's admission wait (optional)

- **Requirements:** R-SYN-3, C2.
- **Why a device:** after a release over 10,000 changed members with 10,000 waiting places, nothing is admitted for
  141-149 ms on the host (the draft's figure; 131-143 ms to the follow's end by the ruling's); S3-R11 item 4 (R2)
  accepts it as a Stage 5 risk, not measured on a device (`docs/DECISIONS.md:641`).
- **Steps:** a manifest change that moves 10,000 members while 10,000 requests wait.
- **Observe:** the time from the sync's `commit` to the first waiting request's return (the probe app sees nothing
  finer; the engine's admission needs the bundle).
- **Pass:** figure recorded.

## 10. Observability

### DT-OBS-01 · Reading S1's line back through `OSLogStore`

- **Requirements:** R-OBS-1.
- **Why a device:** whether the unified log keeps `OSLogType.info` messages long enough for an app's `OSLogStore`
  read to return S1's `long purge turn` line is system policy (§5 row :292; `docs/DECISIONS.md:612`, `:658`). The kit
  never calls `OSLogStore`; the tests read the injected `LogSink` tap.
- **Prerequisite:** verify `OSLogStore`'s declarations against the installed SDK's OSLog interface before writing the
  probe app's reader (C7).
- **Steps:** produce S1 lines (DT-PERF-02); read them back through `OSLogStore` from the probe app at once, after
  10 minutes, after a relaunch, after a day.
- **Pass:** retention recorded. If the line cannot be read back, collecting the signal (Stage 4's decision,
  `docs/DECISIONS.md:658`) has to use the app's own `LogSink` or tap, as the probe app does (§3.2).

### DT-OBS-02 · No secret in the device log; the signposts exist

- **Requirements:** R-SEC-1, R-OBS-1.
- **Why a device:** the host tests assert on the `LogTap`; no test writes to the unified log
  (`docs/ARCHITECTURE.md:977`), so `OSLogSink`'s output was never read on a device.
- **Steps:** with a test key and `.acceptedByOwner` against the test origin only, run a sync, a purge and a failure
  (a 404); collect every `com.ztron.assetkit` message from Console; search them for the key's value without pasting
  the key into the record; open the os_signpost instrument.
- **Pass:** the key appears nowhere; the intervals plan, transfer, verify, commit, gc and eviction appear under the
  categories R-OBS-1 names.

## 11. Platform floor (a second device)

### DT-FLR-01 · Launch and the core flows on iOS 15

- **Requirements:** R-ENV-2, R-APL-5.
- **Why a device:** launching a floor-15 binary on iOS 15 (the weak BackgroundAssets link, the strong
  `libswiftSystem`) was checked through `otool` and the runtime's file trees only; iOS 15 simulators cannot boot on
  the host (§5 row :290; `docs/APPLE-API-VERIFICATION.md:183`; S3-B-130).
- **Steps:** install the probe app on the iOS 15 device (and on an iOS 16 or 17 one if available); launch; run
  `sync(.force)`, a `lookup`, a `resolve`, a prefetch window, a purge and `shutdown()`. Whether Xcode 27.0 installs on
  and debugs an iOS 15 device was not checked; if it does not, install through TestFlight.
- **Pass:** no launch failure; the CloudFront tier serves (below iOS 26, R-APL-5); every flow completes as on the main
  device.

### DT-FLR-02 · The shims at run time below iOS 17

- **Requirements:** R-CAR-6, R-ENV-2.
- **Why a device:** the shims ran on the iOS 27 simulator and macOS 27 only; their iOS 15 build is the typecheck
  recorded at `409db9a` (S3-B-118).
- **Steps:** in the adopted carousel app (§12), or a probe build that calls the shims, repeat DT-FLR-01's flows
  through the shim API.
- **Pass:** each shim call behaves as on iOS 27.

## 12. The adopted app: lookup, legacy migration and shims

These need the carousel app adopted: Stage 4 was cancelled, and adoption is a follow-up the owner performs (ADR-006,
`docs/DECISIONS.md:39`; S3-B-120). Until then they are not run.

### DT-KIT-01 · `MainBundleLookup` against an app bundle

- **Requirements:** R-CAR-2.
- **Why a device:** the live `MainBundleLookup` against an app bundle with resources is unverified (S3-B-099).
- **Steps:** ship one asset in the app bundle and the same id remotely; look it up offline and online.
- **Pass:** the fallback chain's first step finds the bundled asset synchronously (bundle, then local, then network;
  R-CAR-2).

### DT-MIG-01 · Legacy migration from the prior-art app

- **Requirements:** R-STO-11, R-STO-2.
- **Why a device:** the Caches to Application Support rename on one APFS volume, a root on another volume,
  `LiveLegacyDefaults`, Unicode normalisation or case differences, the overlap guard's identity walks and sandbox stat
  refusals, and phase 3's ordered against durable commit (OI-2) were tested over a fake volume only (S3-B-036); the
  migration window and its device costs have no benchmark (S3-B-121).
- **Steps:** install the prior-art carousel build and let it download its CDN assets (`Library/Caches/CDNAssets`);
  upgrade in place to the adopted build; launch offline, then online; once, Exit during the migration.
- **Observe:** the `store` migration lines (`Sources/ZTronAssetStorage/Migration/LegacyPhases.swift`); requests at the
  origin; the window's length.
- **Pass:** every file whose checksum verifies is adopted, moved and not downloaded again; the rest is dropped; the
  legacy directory is removed (R-STO-11) and the legacy sync keys are removed (R-STO-2); the interrupted run completes
  at the next launch.

### DT-MIG-02 · The shims' live paths

- **Requirements:** R-CAR-6, Q-10.
- **Why a device:** `NetworkAvailabilityMonitor.shared` over the live reachability conformer,
  `StaticManifestCDNProvider` against a real origin and the 403 a keyless client gets, `defaultAppVersion()` inside an
  app bundle, `BackgroundAssetsCDNProvider` on a device and `CDNLocalStore(baseDirectory:)` over the live file system
  ran over fakes only (S3-B-119); Q-10's adoption was never built (S3-B-120).
- **Steps:** exercise each path in the adopted app.
- **Pass:** each behaves as `docs/MIGRATION.md` describes.

## 13. Index: sources to tests

| Source | Tests |
|---|---|
| SPEC §8: background session re-attachment | DT-BG-01 to DT-BG-09 |
| SPEC §8: Apple-hosted packs through TestFlight | DT-APL-01 to DT-APL-10 |
| SPEC §8: low-storage behaviour | DT-STO-01 to DT-STO-07, DT-APL-09 |
| SPEC §8: memory warnings | DT-MEM-01, DT-MEM-02 |
| R-STO-8's device check (`SPEC.md:187`) | DT-STO-05 |
| §5 row :279 (removed pack downloaded again) | DT-APL-07 |
| §5 row :280 (pack errors; a full disk as `insufficientSpace`) | DT-APL-09 |
| §5 row :281 (`installedBytes` ≈ download size) | DT-APL-03 |
| §5 row :282 (cancellation; abandoned flights) | DT-APL-05 |
| §5 row :283 (networks, cellular data, Low Data Mode) | DT-APL-06 |
| §5 row :284 (resume data, 206, stale data) | DT-BG-04 |
| §5 row :285 (fresh ranged 206) | DT-BG-05 |
| §5 row :286 (`taskDescription`, `forStart`, overload) | DT-BG-06 |
| §5 row :287 (background-session behaviour; the hook; R-NET-3's run-time half) | DT-BG-01, DT-BG-02, DT-BG-03, DT-BG-07 |
| §5 row :288 (`fclonefileat`; optimisation not built) | DT-APL-04 (optional) |
| §5 row :289 (in-place `url(for:)`; not used) | DT-APL-08 (optional) |
| §5 row :290 (iOS 15 launch) | DT-FLR-01 |
| §5 row :291 (essential packs before the first launch) | DT-APL-02 |
| §5 row :292 (`OSLogStore` retention of S1's line) | DT-OBS-01 |
| §5 row :293 (opportunistic above important capacity) | DT-STO-03 |
| §5 row :294 (`NWPathMonitor`'s first callback) | DT-NET-02 |
| §5 row :295 (UIKit's second handler) | DT-BG-02 |
| §5 row :296 (the last priority written) | DT-BG-08 |
| §5 row :297 (`unlink` stalls on a device) | DT-PERF-03 (stalls), DT-PERF-01 (P-13's p99) |
| S3-B-004 (R-MAN-3's allocation bound) | DT-MEM-03 |
| S3-B-009 (no memory-pressure source in `.live()`) | DT-MEM-01, DT-MEM-02 |
| S3-B-021 (fsync semantics and cost, file protection, iOS 15 runtime, P-5 and P-13) | DT-STO-05, DT-STO-06, DT-PERF-03, DT-FLR-01; §14 |
| S3-B-022 (rename, `lstat`/`pread` errors, the undo window) | DT-STO-06 |
| S3-B-036 (legacy migration on a device) | DT-MIG-01 |
| S3-B-037 (the incarnation check) | DT-STO-07 |
| S3-B-038 (C-22's holds, `apply`'s chunked eviction, a purge's wait, the prefilter's spread) | DT-PERF-03 (traces; the purge's wait); DT-PERF-01 (the C2 figures); the prefilter's spread is not observable (DT-PERF-03) |
| S3-B-046 (fresh ranged 206) | DT-BG-05 |
| S3-B-047 (`taskDescription` across a relaunch) | DT-BG-06 |
| S3-B-049 (resume data end to end) | DT-BG-04 |
| S3-B-050 (the live driver; mutant ME) | DT-BG-01, DT-BG-04, DT-BG-07 |
| S3-B-051 (path transitions, D-18.5, HTTP/2) | DT-NET-01, DT-NET-02, DT-NET-04 |
| S3-B-054 (R-NET-3's run-time half) | DT-BG-03 |
| S3-B-060 (the live pack backend) | DT-APL-03, DT-APL-06, DT-APL-09 |
| S3-B-061 (cancellation; a failed removal) | DT-APL-05, DT-APL-10 |
| S3-B-066 (ENOSPC churn) | DT-STO-02 |
| S3-B-094 (replaced-root limits) | DT-STO-04 |
| S3-B-098 (a real `rootVanished`) | DT-STO-04 |
| S3-B-099 (the UIKit hook; `MainBundleLookup`) | DT-BG-02, DT-KIT-01 |
| S3-B-100 (P-8, P-9 and C2 on a device) | DT-PERF-01, DT-PERF-02, DT-PERF-04 |
| S3-B-118 (the shims below iOS 17) | DT-FLR-02 |
| S3-B-119 (the shims' live paths) | DT-MIG-02 |
| S3-B-120 (Q-10's adoption) | DT-KIT-01, DT-MIG-01, DT-MIG-02 (blocked) |
| S3-B-121 (the migration window's device costs) | DT-MIG-01 |
| S3-B-127 (the Apple-hosting setup) | DT-APL-01 |
| S3-B-130 (simulator only; the iOS 15 runtime) | DT-FLR-01 |
| ADR-057's Stage 5 lists (`docs/DECISIONS.md:644`, `:646`, `:652`, `:659`) | the S3-B rows above; UIKit's second handler DT-BG-02; the live write order and the last priority DT-BG-08; C2 on a device DT-PERF-01, DT-PERF-02; `OSLogStore` DT-OBS-01; S3-B-066 DT-STO-02 |
| ADR-057's Not verified, device items (`docs/DECISIONS.md:669-674`) | thermal and Low Power Mode DT-PWR-01; `NWPathMonitor` DT-NET-02; UIKit's second handler DT-BG-02; the live write order and the last priority DT-BG-08; a rewrite to an old task identifier after its name was created anew DT-BG-08 if it occurs, else §14; S3C-2's per-turn costs and S3-B-038's items DT-PERF-03, DT-PERF-01; the barrier's admission wait DT-PERF-05; WP-A/WP-H's changed lines through the flows of §4 to §8 and DT-FLR-01 |
| ARCHITECTURE §14's device list (`docs/ARCHITECTURE.md:981`) | §4, §5, DT-STO-05, DT-STO-06, DT-NET-01, DT-NET-04, DT-FLR-01, DT-MIG-01 |

## 14. Not in this plan

- The benchmark bundle on the iOS Simulator (built, not run, ADR-051; part of S3-B-100), and P-5 and P-13 on a quiet
  host (part of S3-B-021), are host tasks for `docs/VERIFICATION.md`.
- Host-only gaps (the loopback server's LAN refusal, S3-B-108; the model tests' liveness phase, S3-B-079) and the
  accepted risks without a device angle are in `docs/RESIDUAL-RISKS.md`.
- Staging a priority rewrite to an old task identifier after the same attempt's name was created anew (WP-D,
  `docs/DECISIONS.md:673`; `docs/adr-drafts/s3d.md:141-142`). The name must be re-created between the coordinator's
  listing and the live driver's write (`BackgroundSupport.swift:446-484`). Only a seam holds that window open, and
  the only hold, `holdNextPriority()`, is the fake driver's
  (`Tests/ZTronAssetTransportTests/FakeBackgroundSessionDriver.swift:264`); a debugger pause stops the whole app.
  DT-BG-08 records such a write if one occurs; otherwise the item stays as ADR-057 lists it, checked by reading only.
