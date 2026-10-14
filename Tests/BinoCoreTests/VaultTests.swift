import XCTest
@testable import BinoCore

final class VaultTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bino-test-\(UUID().uuidString)")
        setenv("BINO_HOME", home.path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        unsetenv("BINO_HOME")
    }

    func testRoundTrip() throws {
        XCTAssertFalse(VaultStore.exists)
        let vault = Vault.sample
        try VaultStore.save(vault, createTestVault: true)
        XCTAssertTrue(VaultStore.exists)
        XCTAssertEqual(try VaultStore.unlock(reason: "test"), vault)
    }

    func testNothingReadableOnDisk() throws {
        try VaultStore.save(.sample, createTestVault: true)
        let raw = try Data(contentsOf: BinoPaths.vaultFile)
        let text = String(decoding: raw, as: UTF8.self)
        for secret in ["4242", "practice-only-password", "X12345678", "Rivera", "alex.rivera"] {
            XCTAssertFalse(text.contains(secret), "\(secret) is readable in the vault file")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: BinoPaths.vaultFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLoginIndexAnswersWithoutNamingSites() throws {
        XCTAssertNil(LoginIndex.hasLogin(forSite: "united.com"), "no index before the first save")
        var vault = Vault.sample
        var login = Login()
        login.site = "https://www.United.com/account"
        login.username = "someone"
        login.password = "secret"
        vault.logins.append(login)
        var noSite = Login()
        noSite.username = "no-site"
        vault.logins.append(noSite)
        try VaultStore.save(vault, createTestVault: true)

        XCTAssertEqual(LoginIndex.hasLogin(forSite: "united.com"), true)
        XCTAssertEqual(LoginIndex.hasLogin(forSite: "login.united.com"), true)
        XCTAssertEqual(LoginIndex.hasLogin(forSite: "localhost"), true)
        XCTAssertEqual(LoginIndex.hasLogin(forSite: "notunited.com"), false)
        XCTAssertEqual(LoginIndex.hasLogin(forSite: "united.com.evil.io"), false)
        XCTAssertEqual(LoginIndex.hasLogin(forSite: "com"), false)

        let text = String(decoding: try Data(contentsOf: BinoPaths.loginIndexFile), as: UTF8.self)
        for word in ["united", "localhost", "someone", "secret", "alex"] {
            XCTAssertFalse(text.lowercased().contains(word), "\(word) is readable in the login index")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: BinoPaths.loginIndexFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        // The answers agree with what the vault itself would do on those pages.
        XCTAssertNotNil(vault.login(forPage: "https://login.united.com/"))
        XCTAssertNil(vault.login(forPage: "https://notunited.com/"))

        // Removing the login removes it from the index on the next save.
        vault.logins.removeAll { $0.username == "someone" }
        try VaultStore.save(vault, createTestVault: true)
        XCTAssertEqual(LoginIndex.hasLogin(forSite: "united.com"), false)
    }

    func testTamperingIsDetected() throws {
        try VaultStore.save(.sample, createTestVault: true)
        var sealed = try JSONDecoder().decode(SealedVault.self, from: Data(contentsOf: BinoPaths.vaultFile))
        sealed.sealed[sealed.sealed.count / 2] ^= 0x01
        try JSONEncoder().encode(sealed).write(to: BinoPaths.vaultFile)
        XCTAssertThrowsError(try VaultStore.unlock(reason: "test"))
    }

    func testEachSaveUsesAFreshKey() throws {
        try VaultStore.save(.sample, createTestVault: true)
        let first = try Data(contentsOf: BinoPaths.vaultFile)
        try VaultStore.save(.sample, createTestVault: true)
        XCTAssertNotEqual(first, try Data(contentsOf: BinoPaths.vaultFile))
    }

    func testTestKeysAreRefusedInTheRealLocation() {
        unsetenv("BINO_HOME")
        XCTAssertFalse(BinoPaths.isRedirected)
        XCTAssertThrowsError(try VaultKey.create(testKey: true)) { error in
            guard case VaultError.softwareKeyNotAllowed = error else { return XCTFail("wrong error: \(error)") }
        }
        setenv("BINO_HOME", home.path, 1)
    }

    func testAVaultSavedBeforeAFieldExistedStillOpens() throws {
        var vault = Vault.sample
        vault.profile.ssn = "000-12-3456"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(vault)) as? [String: Any])
        var profile = try XCTUnwrap(json["profile"] as? [String: Any])
        XCTAssertEqual(profile["ssn"] as? String, "000-12-3456")
        profile["ssn"] = nil
        json["profile"] = profile

        let older = try JSONDecoder().decode(Vault.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(older.profile.ssn, "")
        XCTAssertEqual(older.profile.firstName, "Alex")
        XCTAssertEqual(older.profile.passport, vault.profile.passport)
        XCTAssertEqual(older.profile.loyalty, vault.profile.loyalty)
        XCTAssertEqual(older.logins, vault.logins)
    }

    func testSocialSecurityNumberIsNeverOfferedToAPage() {
        var vault = Vault.sample
        vault.profile.ssn = "000-12-3456"
        let resolver = ValueResolver(vault: vault, pageURL: "https://www.practiceair.com/apply")
        let box = PageField(id: "1", label: "Social Security number")
        for concept in Concept.allCases {
            if case .text(let value) = resolver.resolve(concept, part: .whole, field: box).resolution {
                XCTAssertFalse(value.filter(\.isNumber).contains("000123456"), "\(concept) offered the SSN")
            }
        }
    }

    func testSearchingLoginsNeverLooksAtThePassword() {
        var login = Login()
        login.note = "Personal Gmail"
        login.site = "google.com"
        login.username = "alex.rivera@example.com"
        login.password = "practice-only-password"

        XCTAssertTrue(login.matches(search: ""))
        XCTAssertTrue(login.matches(search: "  "))
        XCTAssertTrue(login.matches(search: "gmail"))
        XCTAssertTrue(login.matches(search: "GOOGLE"))
        XCTAssertTrue(login.matches(search: "rivera"))
        XCTAssertTrue(login.matches(search: "personal google"))
        XCTAssertFalse(login.matches(search: "gmail supabase"))
        XCTAssertFalse(login.matches(search: "practice"))
    }
}
