import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var userId: String
    @Published var isOnboarded: Bool
    @Published var goal: String = ""
    @Published var deadline: String = ""
    @Published var caloriesConsumed: Int = 0
    @Published var caloriesTarget: Int = 1800
    @Published var waterGlasses: Int = 0
    @Published var visualJourneyURL: URL? = nil

    init() {
        let stored = UserDefaults.standard.string(forKey: "userId") ?? UUID().uuidString
        UserDefaults.standard.set(stored, forKey: "userId")
        self.userId = stored
        self.isOnboarded = UserDefaults.standard.bool(forKey: "isOnboarded")
        self.goal = UserDefaults.standard.string(forKey: "goal") ?? ""
        self.deadline = UserDefaults.standard.string(forKey: "deadline") ?? ""
    }

    func completeOnboarding(goal: String, deadline: String) {
        self.goal = goal
        self.deadline = deadline
        self.isOnboarded = true
        UserDefaults.standard.set(true, forKey: "isOnboarded")
        UserDefaults.standard.set(goal, forKey: "goal")
        UserDefaults.standard.set(deadline, forKey: "deadline")
    }

    var progressPercent: Double {
        guard caloriesTarget > 0 else { return 0 }
        return min(1.0, Double(caloriesConsumed) / Double(caloriesTarget))
    }

    var daysUntilDeadline: Int? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: deadline) else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: date).day
    }
}
