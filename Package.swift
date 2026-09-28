// swift-tools-version:5.9
import PackageDescription

// TokenX: token management for apps that use AI models. The manifest stays at the
// repository root so the package can be added by URL; sources live in ios/ next to android/.
let package = Package(
    name: "TokenX",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [
        // The library: providers, catalog, profiles, repositories (SQLite), the server and the client. Pure Foundation.
        .library(name: "TokenX", targets: ["TokenX"]),
        // Apple secret storage: an AES-GCM cipher whose key lives in the Keychain.
        .library(name: "TokenXApple", targets: ["TokenXApple"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "ios/Sources/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]),
        .target(name: "TokenX", dependencies: ["CSQLite"], path: "ios/Sources/TokenX"),
        .target(name: "TokenXApple", dependencies: ["TokenX"], path: "ios/Sources/TokenXApple"),
        .testTarget(name: "TokenXTests", dependencies: ["TokenX"], path: "ios/Tests/TokenXTests"),
    ]
)
