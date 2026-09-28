//
//  TokenXModel.swift
//  TokenXApple
//
//  What a host app holds: `TokenX.standard(appId:)` builds a server in the
//  app's private storage with the Keychain cipher, and `TokenXModel` wraps a
//  server as an observable object for settings screens (TokenXUI's or the
//  app's own).
//

import Foundation
import TokenX
#if canImport(Combine)
import Combine

public enum TokenXBootstrap {
    /// A server backed by `Application Support/<appId>/tokenx.sqlite` and a Keychain-held cipher key.
    /// Falls back to an in-memory store if the file cannot be opened, so the app keeps running.
    public static func standard(appId: String, transport: HttpTransport = URLSessionTransport()) -> TokenServer {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(appId, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store: TokenStore = (try? SQLiteStore(path: directory.appendingPathComponent("tokenx.sqlite").path)) ?? InMemoryStore()
        #if canImport(CryptoKit) && canImport(Security)
        let cipher: SecretCipher = KeychainCipher(service: appId + ".tokenx")
        #else
        let cipher: SecretCipher = PlainCipher()
        #endif
        return TokenServer(store: store, cipher: cipher, transport: transport)
    }
}

/// The server as an observable object: settings, configured providers, today's usage, and the commands a settings screen needs.
@MainActor
public final class TokenXModel: ObservableObject {
    public let server: TokenServer
    public let client: TokenClient

    @Published public private(set) var settings: Settings
    @Published public private(set) var configured: [ProviderKind] = []
    @Published public private(set) var usageToday = UsageTotals()
    @Published public private(set) var recent: [UsageRecord] = []
    @Published public var lastError: String?

    public init(server: TokenServer) {
        self.server = server
        self.client = TokenClient(broker: server)
        self.settings = server.settings
        refresh()
    }

    /// `TokenX.standard(appId:)` wrapped in a model.
    public convenience init(appId: String) { self.init(server: TokenXBootstrap.standard(appId: appId)) }

    public var isReady: Bool { server.isReady }
    public var activeProvider: ProviderKind? { settings.activeProvider }

    /// The model a profile runs on right now, for display.
    public func modelName(for profile: Profile) -> String? { server.model(for: profile).map { "\($0.name) (\($0.provider.displayName))" } }

    public func hasKey(_ provider: ProviderKind) -> Bool { configured.contains(provider) }

    public func refresh() {
        settings = server.settings
        configured = server.configuredProviders
        usageToday = server.usageToday()
        recent = server.recentUsage(limit: 20)
    }

    /// Stores the key (when given) and makes the provider active.
    public func activate(_ provider: ProviderKind, key: String? = nil) {
        run { try server.activate(provider, key: key?.isEmpty == false ? key : nil) }
    }

    public func removeKey(for provider: ProviderKind) { run { try server.setKey(nil, for: provider) } }

    public func update(_ change: (inout Settings) -> Void) { run { try server.update(change) } }

    public func setLocalServer(url: String?, model: String?) {
        run { try server.update { $0.localBaseURL = url?.isEmpty == false ? url : nil; $0.localModel = model?.isEmpty == false ? model : nil } }
    }

    public func clearUsage() { run { try server.store.deleteAll() } }

    private func run(_ body: () throws -> Void) {
        do { try body(); lastError = nil } catch { lastError = "\(error)" }
        refresh()
    }
}
#endif
