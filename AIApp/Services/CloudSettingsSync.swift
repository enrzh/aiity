import Foundation

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
enum CloudSettingsSync {
    private static let store = NSUbiquitousKeyValueStore.default
    private static var observedKeys: Set<String> = []

    /// Call once per key, at the point that key's owner is created. Adopts
    /// whatever iCloud already has if this device has nothing yet (fresh
    /// install or a new device), then keeps listening for changes pushed
    /// from other devices while the app is running.
    static func adopt(key: String, onChange: @escaping (Data) -> Void) {
        if UserDefaults.standard.data(forKey: key) == nil,
           let remote = store.data(forKey: key) {
            UserDefaults.standard.set(remote, forKey: key)
            onChange(remote)
        }
        guard !observedKeys.contains(key) else { return }
        observedKeys.insert(key)
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { notification in
            guard let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
                  keys.contains(key),
                  let data = store.data(forKey: key) else { return }
            UserDefaults.standard.set(data, forKey: key)
            onChange(data)
        }
        store.synchronize()
    }

    /// Call every time the value is saved locally, right after the
    /// UserDefaults write.
    static func push(key: String, data: Data) {
        store.set(data, forKey: key)
    }
}
