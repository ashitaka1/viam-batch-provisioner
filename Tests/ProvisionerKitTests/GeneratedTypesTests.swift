import Foundation
import ProvisionerAPI
import Testing

@Test func queueListDecodes() throws {
    let json = Data("""
        {"last_event_id": 7, "entries": [{"name": "a", "status": "installing", "has_credentials": true, "mac": "aa:bb:cc:dd:ee:ff"}]}
        """.utf8)
    let list = try JSONDecoder().decode(Components.Schemas.QueueList.self, from: json)
    #expect(list.lastEventId == 7)
    #expect(list.entries.map(\.status) == [.installing])
}
