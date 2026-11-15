// The README's quick adoption snippet, compiled with this target under Swift 6 and warnings as errors (ADR-058).
// `QuickAdoptionTests` holds the README to the lines between the two markers, with one stated difference: the
// README's `@main` line is left out here, because a test bundle is not an executable.

// README:BEGIN
import SwiftUI
import ZTronAssetSwiftUI

struct CarouselApp: App {
    // One library for the app's lifetime, described by a chain; nothing is opened until `start()`.
    @StateObject private var assets = AssetLibrary
        .origin(URL(string: "https://assets.example.com/")!)   // the CloudFront distribution
        .appKey("PLACEHOLDER-APP-KEY")                          // from secure configuration; never logged
        .retain(.tags(["free"]))                                // what a sync keeps on the device
        .refresh(.atMostEvery(24 * 60 * 60))                    // at most one launch sync a day
        .bundled(.image)                                        // images also ship in the app bundle
        .library()

    var body: some Scene {
        WindowGroup {
            CarouselPage(id: "page-1")
                .environmentObject(self.assets)
                .task { await self.assets.start() }             // opens the store, launches the due sync
        }
    }
}

struct CarouselPage: View {
    @EnvironmentObject private var assets: AssetLibrary
    let id: AssetID
    @State private var file: Result<URL, AssetError>?

    var body: some View {
        VStack {
            switch self.file {
            case .success(let url)?: AsyncImage(url: url)
            case .failure(let error)?: Text("Unavailable: \(String(describing: error))")
            case nil: ProgressView()
            }
            if case .running(let progress?) = self.assets.syncActivity {
                ProgressView(value: progress.fraction)          // published state: the sync in flight
            }
        }
        .task(id: self.id) {
            self.file = nil
            let file: Result<URL, AssetError>
            do throws(AssetError) {
                // Bundle, then local store, then network; the page on screen overtakes any sync.
                file = .success(try await self.assets.url(for: self.id, kind: .image))
            } catch {
                file = .failure(error)
            }
            if !Task.isCancelled {
                self.file = file                                // a page that moved on keeps its own state
            }
        }
    }
}
// README:END
