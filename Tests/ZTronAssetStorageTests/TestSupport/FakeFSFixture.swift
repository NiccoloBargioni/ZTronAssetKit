import Foundation
import ZTronAssetModel
import ZTronAssetTestSupport

/// Shared helpers of the WP-H fake tests (namespaced so no other package's helpers can collide).
enum FakeFSFixture {
    /// The fake volume's root.
    static let volume = URL(fileURLWithPath: "/fake-volume", isDirectory: true)

    /// A file URL on the fake volume.
    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    /// A fresh fake on `disk`, with its own manual clock.
    @available(macOS 15.0, *)
    static func make(
        _ disk: DiskImage = DiskImage(),
        crashBefore: Int? = nil,
        mode: CrashMode = .processKill,
        important: Int64 = 64 << 30,
        opportunistic: Int64 = 64 << 30
    ) -> FakeFileSystem {
        FakeFileSystem(
            disk: disk,
            time: ManualTimeSource(),
            configuration: FakeFileSystemConfiguration(
                crashBefore: crashBefore,
                crashMode: mode,
                importantCapacity: important,
                opportunisticCapacity: opportunistic
            )
        )
    }

    /// The disk a power loss that drops un-synced state would leave now.
    @available(macOS 15.0, *)
    static func powerLoss(_ disk: DiskImage, _ mode: CrashMode = .powerLossDropUnsynced) -> DiskImage {
        FakeFFSLifetime.next(disk, mode: mode).survivingDisk()
    }

    /// A file's whole content, or `nil` when it cannot be read.
    @available(macOS 15.0, *)
    static func content(_ fileSystem: FakeFileSystem, _ path: String) -> [UInt8]? {
        guard let data = try? fileSystem.read(from: FakeFSFixture.url(path), offset: 0, maxLength: 1 << 20) else {
            return nil
        }
        return [UInt8](data)
    }
}

/// Starts the next lifetime of a disk.
enum FakeFFSLifetime {
    /// A fake on `disk` whose `survivingDisk()` applies `mode` now.
    @available(macOS 15.0, *)
    static func next(_ disk: DiskImage, mode: CrashMode = .processKill) -> FakeFileSystem {
        FakeFSFixture.make(disk, mode: mode)
    }
}
