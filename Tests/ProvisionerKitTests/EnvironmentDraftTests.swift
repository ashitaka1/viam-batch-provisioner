import Foundation
import ProvisionerKit
import Testing

@Suite struct EnvironmentDraftTests {
    private let saved: Environment = {
        var environment = Environment.new(name: "Shop")
        environment.namePrefix = "test"
        environment.username = "viam"
        environment.wifiSSID = nil
        environment.packages = ["htop"]
        return environment
    }()

    @Test func valueReadsPackagesOnePerLineWithoutBlanks() {
        var draft = EnvironmentDraft(saved)
        draft.packagesText = " htop \n\n  jq\n"
        #expect(draft.value.packages == ["htop", "jq"])
    }

    @Test func storedChangeReplacesADraftWithNoUnsavedEdit() {
        var draft = EnvironmentDraft(saved)
        var undone = saved
        undone.namePrefix = "before"
        undone.wifiSSID = "shop"
        undone.packages = ["vim"]
        draft.storedChanged(from: saved, to: undone)
        #expect(draft.environment == undone)
        #expect(draft.packagesText == "vim")
    }

    @Test func storedChangeKeepsAnUnsavedEditAndTakesEveryOtherField() {
        var draft = EnvironmentDraft(saved)
        draft.environment.namePrefix = "tcos-test"
        var changed = saved
        changed.name = "Shop 2"
        changed.username = "ops"
        changed.hasPassword = true
        draft.storedChanged(from: saved, to: changed)
        #expect(draft.environment.namePrefix == "tcos-test")
        #expect(draft.environment.name == "Shop 2")
        #expect(draft.environment.username == "ops")
        #expect(draft.environment.hasPassword)
    }

    @Test func storedChangeTakesAFieldThatBecameNil() {
        var withSSID = saved
        withSSID.wifiSSID = "shop"
        var draft = EnvironmentDraft(withSSID)
        draft.environment.namePrefix = "tcos-test"
        draft.storedChanged(from: withSSID, to: saved)
        #expect(draft.environment.wifiSSID == nil)
        #expect(draft.environment.namePrefix == "tcos-test")
    }

    @Test func storedChangeKeepsAFieldBothChanged() {
        var draft = EnvironmentDraft(saved)
        draft.environment.namePrefix = "typed"
        var changed = saved
        changed.namePrefix = "stored"
        draft.storedChanged(from: saved, to: changed)
        #expect(draft.environment.namePrefix == "typed")
    }

    @Test(arguments: ["htop\njq", "htop\n"])
    func storedChangeKeepsUnsavedPackagesText(typed: String) {
        var draft = EnvironmentDraft(saved)
        draft.packagesText = typed
        var changed = saved
        changed.name = "Shop 2"
        changed.packages = ["vim"]
        draft.storedChanged(from: saved, to: changed)
        #expect(draft.packagesText == typed)
        #expect(draft.environment.name == "Shop 2")
    }
}
