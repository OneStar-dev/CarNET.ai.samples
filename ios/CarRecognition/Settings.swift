import Foundation
import Security

/// The app's two settings: the API address (in UserDefaults) and the API key (in the keychain).
enum Settings {
    static var address: String {
        get { UserDefaults.standard.string(forKey: "apiAddress") ?? CarnetClient.cloudAddress }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiAddress") }
    }

    static var key: String {
        get { Keychain.read() ?? "" }
        set { Keychain.save(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static var client: CarnetClient { CarnetClient(address: address, key: key) }
}

/// Keeps the API key in the keychain, readable only by this app on this device.
private enum Keychain {
    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "carnet-api-key"]
    }

    static func read() -> String? {
        var found: AnyObject?
        var search = query
        search[kSecReturnData] = true
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(key.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
