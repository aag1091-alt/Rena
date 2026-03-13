import SwiftUI
import Combine

class AppState: ObservableObject {
    // Auth
    @Published var userId: String = ""
    @Published var isSignedIn: Bool = false

    // Onboarding
    @Published var isOnboarded: Bool = false
    @Published var hasGoal: Bool = false

    // Profile
    @Published var name: String = ""
    @Published var email: String = ""

    // Daily progress (populated from /progress)
    @Published var goal: String = ""
    @Published var deadline: String = ""
    @Published var caloriesConsumed: Int = 0
    @Published var caloriesTarget: Int = 1800
    @Published var waterGlasses: Int = 0
    @Published var mealsLogged: [MealEntry] = []
    @Published var visualJourneyURL: URL? = nil

    init() {
        userId = UserDefaults.standard.string(forKey: "userId") ?? ""
        isSignedIn = !userId.isEmpty
        isOnboarded = UserDefaults.standard.bool(forKey: "isOnboarded")
        hasGoal = UserDefaults.standard.bool(forKey: "hasGoal")
        name = UserDefaults.standard.string(forKey: "userName") ?? ""
        email = UserDefaults.standard.string(forKey: "userEmail") ?? ""
        goal = UserDefaults.standard.string(forKey: "goal") ?? ""
        deadline = UserDefaults.standard.string(forKey: "deadline") ?? ""
    }

    func signIn(userId: String, email: String, name: String) {
        self.userId = userId
        self.email = email
        self.name = name
        self.isSignedIn = true
        UserDefaults.standard.set(userId, forKey: "userId")
        UserDefaults.standard.set(email, forKey: "userEmail")
        UserDefaults.standard.set(name, forKey: "userName")
    }

    func completeOnboarding(name: String, caloriesTarget: Int) {
        self.name = name
        self.caloriesTarget = caloriesTarget
        self.isOnboarded = true
        UserDefaults.standard.set(true, forKey: "isOnboarded")
        UserDefaults.standard.set(name, forKey: "userName")
    }

    func goalDetected(goal: String, deadline: String) {
        self.goal = goal
        self.deadline = deadline
        self.hasGoal = true
        UserDefaults.standard.set(true, forKey: "hasGoal")
        UserDefaults.standard.set(goal, forKey: "goal")
        UserDefaults.standard.set(deadline, forKey: "deadline")
    }

    func signOut() {
        userId = ""
        isSignedIn = false
        isOnboarded = false
        hasGoal = false
        name = ""
        email = ""
        goal = ""
        deadline = ""
        UserDefaults.standard.removeObject(forKey: "userId")
        UserDefaults.standard.removeObject(forKey: "userEmail")
        UserDefaults.standard.removeObject(forKey: "userName")
        UserDefaults.standard.removeObject(forKey: "isOnboarded")
        UserDefaults.standard.removeObject(forKey: "hasGoal")
        UserDefaults.standard.removeObject(forKey: "goal")
        UserDefaults.standard.removeObject(forKey: "deadline")
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
