import CryptoKit

/// The `$6$` password hash cloud-init and autoinstall take, from Drepper's
/// "Unix crypt using SHA-256 and SHA-512". The app computes it itself because
/// macOS's LibreSSL `openssl passwd` can't, which is why `scripts/hash-password.sh`
/// needs mkpasswd or Homebrew's openssl.
public enum SHA512Crypt {
    static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    public static let defaultRounds = 5000

    /// A nil salt draws 16 random characters. Salts longer than 16 are cut to 16,
    /// and rounds are clamped to 1000...999_999_999, as glibc does.
    public static func hash(_ password: String, salt: String? = nil, rounds: Int = defaultRounds) -> String {
        let salt = Array((salt ?? randomSalt()).utf8.prefix(16))
        let rounds = min(max(rounds, 1000), 999_999_999)
        let key = Array(password.utf8)

        let b = digest(key, salt, key)

        var context = SHA512()
        context.update(data: key)
        context.update(data: salt)
        context.update(data: repeated(b, toLength: key.count))
        var length = key.count
        while length > 0 {
            context.update(data: length & 1 == 1 ? b : key)
            length >>= 1
        }
        var c = Array(context.finalize())

        let p = repeated(digest(Array(repeating: key, count: key.count).flatMap { $0 }), toLength: key.count)
        let s = repeated(digest(Array(repeating: salt, count: 16 + Int(c[0])).flatMap { $0 }), toLength: salt.count)

        for round in 0..<rounds {
            var context = SHA512()
            context.update(data: round & 1 == 1 ? p : c)
            if round % 3 != 0 { context.update(data: s) }
            if round % 7 != 0 { context.update(data: p) }
            context.update(data: round & 1 == 1 ? c : p)
            c = Array(context.finalize())
        }

        let prefix = rounds == defaultRounds ? "$6$" : "$6$rounds=\(rounds)$"
        return prefix + String(decoding: salt, as: UTF8.self) + "$" + encode(c)
    }

    private static func digest(_ parts: [UInt8]...) -> [UInt8] {
        var context = SHA512()
        for part in parts { context.update(data: part) }
        return Array(context.finalize())
    }

    private static func repeated(_ bytes: [UInt8], toLength length: Int) -> [UInt8] {
        (0..<length).map { bytes[$0 % bytes.count] }
    }

    private static func randomSalt() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(decoding: (0..<16).map { _ in alphabet.randomElement(using: &generator)! }, as: UTF8.self)
    }

    /// The final byte permutation and crypt's own base64 alphabet.
    private static func encode(_ c: [UInt8]) -> String {
        let triples: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var out: [UInt8] = []
        func emit(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, count: Int) {
            var word = UInt32(b2) << 16 | UInt32(b1) << 8 | UInt32(b0)
            for _ in 0..<count {
                out.append(alphabet[Int(word & 0x3f)])
                word >>= 6
            }
        }
        for (x, y, z) in triples { emit(c[x], c[y], c[z], count: 4) }
        emit(0, 0, c[63], count: 2)
        return String(decoding: out, as: UTF8.self)
    }
}
