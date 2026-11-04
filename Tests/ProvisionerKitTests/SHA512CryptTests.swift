@testable import ProvisionerKit
import Testing

/// Vectors from Drepper's "Unix crypt using SHA-256 and SHA-512" specification.
@Suite struct SHA512CryptTests {
    @Test func defaultRoundsMatchReferenceVector() {
        #expect(SHA512Crypt.hash("Hello world!", salt: "saltstring")
            == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
    }

    @Test func explicitRoundsAndLongSaltMatchReferenceVector() {
        #expect(SHA512Crypt.hash("Hello world!", salt: "saltstringsaltstring", rounds: 10000)
            == "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.")
    }

    @Test func longPasswordMatchesReferenceVector() {
        #expect(SHA512Crypt.hash("we have a short salt string but not a short password", salt: "short", rounds: 77777)
            == "$6$rounds=77777$short$WuQyW2YR.hBNpjjRhpYD/ifIw05xdfeEyQoMxIXbkvr0gge1a1x3yRULJ5CCaUeOxFmtlcGZelFl5CxtgfiAc0")
    }

    @Test func roundsBelowMinimumAreRaisedTo1000() {
        #expect(SHA512Crypt.hash("the minimum number is still observed", salt: "roundstoolow", rounds: 10)
            == "$6$rounds=1000$roundstoolow$kUMsbe306n21p9R.FRkW3IGn.S9NPN0x50YhH1xhLsPuWGsUSklZt58jaTfF4ZEQpyUNGc0dqbpBYYBaHHrsX.")
    }

    /// Computed with Homebrew's `openssl passwd -6 -salt fixedsalt`.
    @Test func matchesOpenSSL() {
        #expect(SHA512Crypt.hash("hunter22", salt: "fixedsalt")
            == "$6$fixedsalt$iex.S17VReJdL1EZyuu7dIuv5gR1qAV5TPbELAc1cAtSZtYPUxRc4eD.JZa.wKO8SfLzOcXVsaWMyzBYsYxau1")
        #expect(SHA512Crypt.hash("pässwörd", salt: "fixedsalt")
            == "$6$fixedsalt$eHkBVXz.s6PmpkQfSQ5hcw66hsDVPW30UC54aiAJDg08RCTy1q6V2mkpuZRImtZ2WHElkblao1LmMY6q4GRVV.")
    }

    @Test func randomSaltIsSixteenCryptCharacters() {
        let parts = SHA512Crypt.hash("pw").split(separator: "$")
        #expect(parts.count == 3)
        #expect(parts[0] == "6")
        #expect(parts[1].count == 16)
        #expect(parts[1].allSatisfy { "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".contains($0) })
        #expect(parts[2].count == 86)
        #expect(SHA512Crypt.hash("pw") != SHA512Crypt.hash("pw"), "each call draws a new salt")
    }
}
