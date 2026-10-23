import Foundation

struct PainEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var date: Date
    var value: Double
    var notes: String

    init(id: UUID = UUID(), date: Date, value: Double, notes: String = "") {
        self.id = id
        self.date = date
        self.value = value
        self.notes = notes
    }
}

extension Array where Element == PainEntry {
    func sortedAscending() -> [PainEntry] {
        sorted { $0.date < $1.date }
    }

    func sortedDescending() -> [PainEntry] {
        sorted { $0.date > $1.date }
    }
}
