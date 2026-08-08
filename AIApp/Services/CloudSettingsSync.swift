import Foundation

/// Seam over `NSUbiquitousKeyValueStore` so the engine can run against a fake
/// in unit tests — the real KVS silently does nothing without an iCloud
/// account on the host, which made this logic untestable as a hardcoded
/// singleton (and KVS never surfaces failures, so a regression here would
/// stop settings sync with no error anywhere).
protocol CloudKeyValueStore: AnyObject {
    func data(forKey aKey: String) -> Data?
    func set(_ aData: Data?, forKey aKey: String)
    @discardableResult
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {}

/// Mirrors small, non-secret UserDefaults blobs into iCloud's key-value
/// store, so the provider you picked, the model, and any base URL follow you
/// to a new device or a reinstall.
///
/// This is deliberately NOT `SyncStatus`/the CloudKit container that syncs
/// `MiniApp` — that is a separate mechanism scoped to mini-apps. Settings this
/// small don't need a database; `NSUbiquitousKeyValueStore` is the right tool
/// and Apple resolves write conflicts between devices on its own.
///
/// Deliberately does NOT sync API keys or account credentials. Keychain.swift
/// stores those `ThisDeviceOnly` on purpose — a compromised or lost device
/// should not leak keys usable against every other device signed into the
/// same Apple ID. Only the non-secret preference syncs; each device still
/// asks for its own key once.
final class CloudSettingsSync {
    static let shared = CloudSettingsSync()

    /// Resolves the blob already on this device against one arriving from
    /// iCloud, returning what should actually be stored. Without one, the
    /// incoming blob wins wholesale (last-writer-wins). With one, a remote
    /// blob can be combined per entry — see `ProviderProfiles.mergedData` —
    /// so e.g. a remote empty model never clobbers a local explicit pick.
    typealias Merge = (_ local: Data, _ incoming: Data) -> Data

    private let store: CloudKeyValueStore
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var handlers: [String: (Data) -> Void] = [:]
    private var merges: [String: Merge] = [:]
    private var observerToken: NSObjectProtocol?

    init(
        store: CloudKeyValueStore = NSUbiquitousKeyValueStore.default,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    /// Call at the point the key's owner is created. Adopts whatever iCloud
    /// already has if this device has nothing yet (fresh install or a new
    /// device), then keeps listening for changes pushed from other devices
    /// while the app is running.
    ///
    /// Calling `adopt` again for the same key REPLACES the previous handler:
    /// when SwiftUI recreates the owning object (a `@StateObject` torn down
    /// and rebuilt), the new instance takes over cleanly. The old registry
    /// silently dropped the second registration, so remote changes kept
    /// firing into a dead owner until relaunch.
    func adopt(key: String, merge: Merge? = nil, onChange: @escaping (Data) -> Void) {
        lock.lock()
        handlers[key] = onChange
        merges[key] = merge
        let needsObserver = observerToken == nil
        lock.unlock()

        if needsObserver { installObserver() }

        if defaults.data(forKey: key) == nil, let remote = store.data(forKey: key) {
            defaults.set(remote, forKey: key)
            onChange(remote)
        }
        store.synchronize()
    }

    /// Call every time the value is saved locally, right after the
    /// UserDefaults write. Pushing a byte-identical blob is skipped — that is
    /// the echo a remote change triggers when its handler re-saves what it
    /// just adopted (encoders here use `.sortedKeys`, so identical state
    /// means identical bytes).
    func push(key: String, data: Data) {
        guard store.data(forKey: key) != data else { return }
        store.set(data, forKey: key)
    }

    private func installObserver() {
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            guard let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
            self?.applyExternalChanges(forKeys: keys)
        }
    }

    /// Apply remote changes for the given keys. Internal (not private) so
    /// tests can drive the exact path the KVS notification takes.
    func applyExternalChanges(forKeys keys: [String]) {
        for key in keys {
            lock.lock()
            let handler = handlers[key]
            let merge = merges[key]
            lock.unlock()

            guard let handler, let remote = store.data(forKey: key) else { continue }
            let local = defaults.data(forKey: key)
            var resolved = remote
            if let local, let merge {
                resolved = merge(local, remote)
            }
            // A blob identical to what this device already has changes
            // nothing — skip the write AND the handler, so a remote echo of
            // our own push cannot ripple back into another save.
            guard resolved != local else { continue }
            defaults.set(resolved, forKey: key)
            handler(resolved)
            // When the merge kept local knowledge the remote blob lacked,
            // publish the union so every device converges on it (the merge is
            // deterministic, and the identical-blob guards stop any loop).
            if resolved != remote {
                store.set(resolved, forKey: key)
            }
        }
    }

    // MARK: - App-wide singleton API (the production call sites)

    static func adopt(key: String, merge: Merge? = nil, onChange: @escaping (Data) -> Void) {
        shared.adopt(key: key, merge: merge, onChange: onChange)
    }

    static func push(key: String, data: Data) {
        shared.push(key: key, data: data)
    }
}
