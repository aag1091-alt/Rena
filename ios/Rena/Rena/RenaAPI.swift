import Foundation
import UIKit

let kBaseURL = "https://rena-agent-879054433521.us-central1.run.app"

// MARK: - Onboard

struct OnboardResponse: Codable {
    let status: String
    let name: String
    let tdee: Int
    let dailyCalorieTarget: Int

    enum CodingKeys: String, CodingKey {
        case status, name, tdee
        case dailyCalorieTarget = "daily_calorie_target"
    }
}

struct ScanResponse: Codable {
    let identified: Bool
    let description: String?
    let totalCalories: Int?
    let totalProteinG: Int?
    let totalCarbsG: Int?
    let totalFatG: Int?
    let confidence: String?
    let logged: Bool?

    enum CodingKeys: String, CodingKey {
        case identified, description, confidence, logged
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
    }
}

struct MealEntry: Identifiable {
    var id: String { loggedAt ?? name }
    let name: String
    let calories: Int
    let proteinG: Int
    let carbsG: Int
    let fatG: Int
    let loggedAt: String?
}

extension MealEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case calories
        case proteinG = "protein_g"
        case carbsG   = "carbs_g"
        case fatG     = "fat_g"
        case loggedAt = "logged_at"
    }

    // Handles both Int and Double from Python/Firestore (e.g. 450 vs 450.0)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name     = try c.decode(String.self, forKey: .name)
        loggedAt = try? c.decode(String.self, forKey: .loggedAt)

        func intOrDouble(_ key: CodingKeys) -> Int {
            if let i = try? c.decode(Int.self,    forKey: key) { return i }
            if let d = try? c.decode(Double.self, forKey: key) { return Int(d) }
            return 0
        }
        calories = intOrDouble(.calories)
        proteinG = intOrDouble(.proteinG)
        carbsG   = intOrDouble(.carbsG)
        fatG     = intOrDouble(.fatG)
    }
}

struct WorkoutEntry: Identifiable, Codable {
    var id: String { "\(type)-\(loggedAt ?? "")" }
    let type: String
    let durationMin: Int
    let caloriesBurned: Int
    let loggedAt: String?

    enum CodingKeys: String, CodingKey {
        case type
        case durationMin    = "duration_min"
        case caloriesBurned = "calories_burned"
        case loggedAt       = "logged_at"
    }
}

struct ProgressResponse: Codable {
    let goal: String
    let deadline: String
    let caloriesConsumed: Int
    let caloriesBurned: Int
    let caloriesTarget: Int
    let caloriesRemaining: Int
    let burnRequired: Int
    let proteinConsumedG: Int
    let proteinTargetG: Int
    let waterGlasses: Int
    let weightKg: Double?
    let mealsLogged: [MealEntry]?
    let workoutsLogged: [WorkoutEntry]?

    enum CodingKeys: String, CodingKey {
        case goal, deadline
        case caloriesConsumed  = "calories_consumed"
        case caloriesBurned    = "calories_burned"
        case caloriesTarget    = "calories_target"
        case caloriesRemaining = "calories_remaining"
        case burnRequired      = "burn_required"
        case proteinConsumedG  = "protein_consumed_g"
        case proteinTargetG    = "protein_target_g"
        case waterGlasses      = "water_glasses"
        case weightKg          = "weight_kg"
        case mealsLogged       = "meals_logged"
        case workoutsLogged    = "workouts_logged"
    }
}

struct GoalResponse: Codable {
    let goal: String
    let goalType: String
    let startValue: Double
    let targetValue: Double
    let currentValue: Double
    let unit: String
    let direction: String
    let progressPercent: Int
    let progressLabel: String
    let deadline: String
    let imageUrl: String?
    let dailyCalorieTarget: Int
    let daysUntilGoal: Int

    enum CodingKeys: String, CodingKey {
        case goal, deadline, unit, direction
        case goalType        = "goal_type"
        case startValue      = "start_value"
        case targetValue     = "target_value"
        case currentValue    = "current_value"
        case progressPercent = "progress_percent"
        case progressLabel   = "progress_label"
        case imageUrl        = "image_url"
        case dailyCalorieTarget = "daily_calorie_target"
        case daysUntilGoal      = "days_until_goal"
    }
}

struct VisualJourneyResponse: Codable {
    let status: String
    let imageUrl: String?
    let progressPercent: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case imageUrl = "image_url"
        case progressPercent = "progress_percent"
    }
}

class RenaAPI {
    static let shared = RenaAPI()
    private let session = URLSession.shared

    private func request(_ urlString: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    func scanImage(userId: String, image: UIImage, autoLog: Bool = false) async throws -> ScanResponse {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw URLError(.badURL)
        }
        let b64 = imageData.base64EncodedString()

        var req = request("\(kBaseURL)/scan", method: "POST")
        let body: [String: Any] = [
            "user_id": userId,
            "image_base64": b64,
            "mime_type": "image/jpeg",
            "auto_log": autoLog
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(ScanResponse.self, from: data)
    }

    func getProgress(userId: String) async throws -> ProgressResponse {
        let req = request("\(kBaseURL)/progress/\(userId)")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(ProgressResponse.self, from: data)
    }

    func onboard(
        userId: String,
        name: String,
        sex: String,
        age: Int,
        heightCm: Double,
        weightKg: Double,
        activityLevel: String
    ) async throws -> OnboardResponse {
        var req = request("\(kBaseURL)/onboard", method: "POST")
        let body: [String: Any] = [
            "user_id": userId,
            "name": name,
            "sex": sex,
            "age": age,
            "height_cm": heightCm,
            "weight_kg": weightKg,
            "activity_level": activityLevel,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(OnboardResponse.self, from: data)
    }

    func getGoal(userId: String) async throws -> GoalResponse {
        let req = request("\(kBaseURL)/goal/\(userId)")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(GoalResponse.self, from: data)
    }

    func devReset(userId: String) async throws {
        let req = request("\(kBaseURL)/dev/reset/\(userId)", method: "DELETE")
        _ = try await session.data(for: req)
    }

    func logWeight(userId: String, weightKg: Double) async throws -> [String: Any] {
        var req = request("\(kBaseURL)/log/weight", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "weight_kg": weightKg])
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func getVisualJourney(userId: String) async throws -> VisualJourneyResponse {
        var req = request("\(kBaseURL)/visual_journey", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId])
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(VisualJourneyResponse.self, from: data)
    }
}
