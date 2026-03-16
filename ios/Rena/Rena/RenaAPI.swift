import Foundation
import UIKit

// Toggle for local dev vs production
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

struct ScanItem: Codable, Identifiable {
    var id: String { name }
    let name: String
    let weightG: Int?
    let calories: Int
    let proteinG: Int
    let carbsG: Int
    let fatG: Int

    enum CodingKeys: String, CodingKey {
        case name, calories
        case weightG  = "weight_g"
        case proteinG = "protein_g"
        case carbsG   = "carbs_g"
        case fatG     = "fat_g"
    }

    init(name: String, weightG: Int? = nil, calories: Int, proteinG: Int, carbsG: Int, fatG: Int) {
        self.name = name; self.weightG = weightG; self.calories = calories
        self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        func intOrDouble(_ key: CodingKeys) -> Int {
            if let i = try? c.decode(Int.self,    forKey: key) { return i }
            if let d = try? c.decode(Double.self, forKey: key) { return Int(d) }
            return 0
        }
        weightG  = intOrDouble(.weightG)
        calories = intOrDouble(.calories)
        proteinG = intOrDouble(.proteinG)
        carbsG   = intOrDouble(.carbsG)
        fatG     = intOrDouble(.fatG)
    }
}

struct ScanResponse: Codable {
    let identified: Bool
    let description: String?
    let items: [ScanItem]?
    let totalCalories: Int?
    let totalProteinG: Int?
    let totalCarbsG: Int?
    let totalFatG: Int?
    let confidence: String?
    let logged: Bool?

    enum CodingKeys: String, CodingKey {
        case identified, description, confidence, logged, items
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Handle identified as Bool, Int, or String (Gemini occasionally varies)
        if let b = try? c.decode(Bool.self, forKey: .identified) {
            identified = b
        } else if let i = try? c.decode(Int.self, forKey: .identified) {
            identified = i != 0
        } else {
            identified = false
        }
        description = try? c.decode(String.self, forKey: .description)
        items       = try? c.decode([ScanItem].self, forKey: .items)
        confidence  = try? c.decode(String.self, forKey: .confidence)
        logged      = try? c.decode(Bool.self, forKey: .logged)
        func intOrDouble(_ key: CodingKeys) -> Int? {
            if let i = try? c.decode(Int.self,    forKey: key) { return i }
            if let d = try? c.decode(Double.self, forKey: key) { return Int(d) }
            return nil
        }
        totalCalories  = intOrDouble(.totalCalories)
        totalProteinG  = intOrDouble(.totalProteinG)
        totalCarbsG    = intOrDouble(.totalCarbsG)
        totalFatG      = intOrDouble(.totalFatG)
    }
}

struct MealEntry: Identifiable {
    var id: String { "\(loggedAt ?? name)-\(name)-\(calories)" }
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
        case dailyCalorieTarget = "daily_calorie_target"
        case daysUntilGoal      = "days_until_goal"
    }
}

// MARK: - Workout Plan Models

struct PlannedExercise: Codable, Identifiable {
    let id: String
    let name: String
    let type: String          // "strength" | "cardio"
    let sets: Int?
    let reps: Int?
    let weightKg: Double?
    let durationMin: Int?
    let caloriesBurned: Int
    let targetMuscles: String?
    var completed: Bool
    var logged: Bool
    var videoUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, sets, reps, completed, logged
        case weightKg      = "weight_kg"
        case durationMin   = "duration_min"
        case caloriesBurned = "calories_burned"
        case targetMuscles = "target_muscles"
        case videoUrl      = "video_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        name           = try c.decode(String.self, forKey: .name)
        type           = try c.decode(String.self, forKey: .type)
        sets           = try? c.decode(Int.self, forKey: .sets)
        reps           = try? c.decode(Int.self, forKey: .reps)
        weightKg       = try? c.decode(Double.self, forKey: .weightKg)
        durationMin    = try? c.decode(Int.self, forKey: .durationMin)
        targetMuscles  = try? c.decode(String.self, forKey: .targetMuscles)
        videoUrl       = try? c.decode(String.self, forKey: .videoUrl)
        completed      = (try? c.decode(Bool.self, forKey: .completed)) ?? false
        logged         = (try? c.decode(Bool.self, forKey: .logged)) ?? false
        if let i = try? c.decode(Int.self, forKey: .caloriesBurned) { caloriesBurned = i }
        else if let d = try? c.decode(Double.self, forKey: .caloriesBurned) { caloriesBurned = Int(d) }
        else { caloriesBurned = 0 }
    }
}

struct PlannedMeal: Codable, Identifiable {
    let id: String
    let mealType: String
    let name: String
    let description: String
    let cookTimeMin: Int
    let calories: Int
    let proteinG: Int
    let carbsG: Int
    let fatG: Int
    let youtubeQuery: String
    var logged: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, logged
        case mealType    = "meal_type"
        case cookTimeMin = "cook_time_min"
        case calories, proteinG = "protein_g", carbsG = "carbs_g", fatG = "fat_g"
        case youtubeQuery = "youtube_query"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        mealType    = (try? c.decode(String.self, forKey: .mealType)) ?? "meal"
        name        = try c.decode(String.self, forKey: .name)
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        logged      = (try? c.decode(Bool.self,   forKey: .logged))      ?? false
        youtubeQuery = (try? c.decode(String.self, forKey: .youtubeQuery)) ?? "\(name) recipe"
        func intOrDouble(_ key: CodingKeys) -> Int {
            if let i = try? c.decode(Int.self,    forKey: key) { return i }
            if let d = try? c.decode(Double.self, forKey: key) { return Int(d) }
            return 0
        }
        cookTimeMin = intOrDouble(.cookTimeMin)
        calories    = intOrDouble(.calories)
        proteinG    = intOrDouble(.proteinG)
        carbsG      = intOrDouble(.carbsG)
        fatG        = intOrDouble(.fatG)
    }
}

extension PlannedMeal {
    init(fromMealEntry name: String, calories: Int, proteinG: Int, carbsG: Int, fatG: Int) {
        self.id          = UUID().uuidString
        self.mealType    = "meal"
        self.name        = name
        self.description = ""
        self.cookTimeMin = 0
        self.calories    = calories
        self.proteinG    = proteinG
        self.carbsG      = carbsG
        self.fatG        = fatG
        self.youtubeQuery = "\(name) recipe"
        self.logged      = true
    }
}

struct PlannedMealPlan: Codable {
    let id: String
    let date: String
    let totalCalories: Int
    let meals: [PlannedMeal]
    let notes: String

    enum CodingKeys: String, CodingKey {
        case id, date, meals, notes
        case totalCalories = "total_calories"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id    = (try? c.decode(String.self,        forKey: .id))    ?? ""
        date  = try  c.decode(String.self,         forKey: .date)
        meals = try  c.decode([PlannedMeal].self,  forKey: .meals)
        notes = (try? c.decode(String.self,        forKey: .notes)) ?? ""
        if let i = try? c.decode(Int.self,    forKey: .totalCalories) { totalCalories = i }
        else if let d = try? c.decode(Double.self, forKey: .totalCalories) { totalCalories = Int(d) }
        else { totalCalories = 0 }
    }
}

struct PlannedWorkout: Codable {
    let id: String
    let name: String
    let date: String
    let totalDurationMin: Int
    let exercises: [PlannedExercise]

    var totalCalories: Int { exercises.reduce(0) { $0 + $1.caloriesBurned } }

    enum CodingKeys: String, CodingKey {
        case id, name, date, exercises
        case totalDurationMin = "total_duration_min"
    }

    // Firestore sometimes returns Int fields as Double (e.g. 45.0)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(String.self, forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        date      = try c.decode(String.self, forKey: .date)
        exercises = try c.decode([PlannedExercise].self, forKey: .exercises)
        if let i = try? c.decode(Int.self,    forKey: .totalDurationMin) { totalDurationMin = i }
        else if let d = try? c.decode(Double.self, forKey: .totalDurationMin) { totalDurationMin = Int(d) }
        else { totalDurationMin = 0 }
    }
}

struct VideoStatus: Codable {
    let status: String      // "ready" | "generating" | "done" | "error"
    let videoUrl: String?
    let jobId: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, message
        case videoUrl = "video_url"
        case jobId    = "job_id"
    }

    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        status  = (try? c.decode(String.self, forKey: .status)) ?? "error"
        videoUrl = try? c.decode(String.self, forKey: .videoUrl)
        jobId    = try? c.decode(String.self, forKey: .jobId)
        message  = try? c.decode(String.self, forKey: .message)
    }
}

class RenaAPI {
    static let shared = RenaAPI()
    private let session = URLSession.shared

    private func request(_ urlString: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    func scanImage(userId: String, image: UIImage, autoLog: Bool = false) async throws -> ScanResponse {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw URLError(.badURL)
        }
        let b64 = imageData.base64EncodedString()

        var req = try request("\(kBaseURL)/scan", method: "POST")
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

    func getProgress(userId: String, date: String? = nil) async throws -> ProgressResponse {
        var urlString = "\(kBaseURL)/progress/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString)
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
        activityLevel: String,
        timezone: String = TimeZone.current.identifier
    ) async throws -> OnboardResponse {
        var req = try request("\(kBaseURL)/onboard", method: "POST")
        let body: [String: Any] = [
            "user_id": userId,
            "name": name,
            "sex": sex,
            "age": age,
            "height_cm": heightCm,
            "weight_kg": weightKg,
            "activity_level": activityLevel,
            "timezone": timezone,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(OnboardResponse.self, from: data)
    }

    func getGoal(userId: String) async throws -> GoalResponse {
        let req = try request("\(kBaseURL)/goal/\(userId)")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(GoalResponse.self, from: data)
    }

    func getWorkbookInsight(userId: String, date: String? = nil) async throws -> (insight: String, activity: String) {
        var urlString = "\(kBaseURL)/workbook/insight/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString)
        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (
                insight:  json["insight"]  as? String ?? "",
                activity: json["activity"] as? String ?? ""
            )
        }
        return ("", "")
    }

    // MARK: - Meal Plan

    func getMealPlan(userId: String, date: String? = nil) async throws -> PlannedMealPlan? {
        var urlString = "\(kBaseURL)/meal-plan/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString)
        let (data, _) = try await session.data(for: req)
        return try? JSONDecoder().decode(PlannedMealPlan.self, from: data)
    }

    func deleteMealPlan(userId: String, date: String? = nil) async throws {
        var urlString = "\(kBaseURL)/meal-plan/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString, method: "DELETE")
        _ = try await session.data(for: req)
    }

    func logMealFromPlan(userId: String, mealId: String, date: String? = nil) async throws {
        var urlString = "\(kBaseURL)/meal-plan/\(userId)/meal/\(mealId)/log"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString, method: "POST")
        _ = try await session.data(for: req)
    }

    func getMorningNudge(userId: String) async throws -> String? {
        let req = try request("\(kBaseURL)/morning-nudge/\(userId)")
        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hasNudge = json["has_nudge"] as? Bool, hasNudge,
           let nudge = json["nudge"] as? String, !nudge.isEmpty {
            return nudge
        }
        return nil
    }

    func getTomorrowPlan(userId: String, date: String? = nil) async throws -> String? {
        var urlString = "\(kBaseURL)/tomorrow-plan/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString)
        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let summary = json["summary"] as? String, !summary.isEmpty {
            return summary
        }
        return nil
    }

    func deleteTomorrowPlan(userId: String, date: String? = nil) async throws {
        var urlString = "\(kBaseURL)/tomorrow-plan/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString, method: "DELETE")
        _ = try await session.data(for: req)
    }

    func devReset(userId: String) async throws {
        let req = try request("\(kBaseURL)/dev/reset/\(userId)", method: "DELETE")
        _ = try await session.data(for: req)
    }

    func devSeed(userId: String) async throws {
        let req = try request("\(kBaseURL)/dev/seed/\(userId)", method: "POST")
        _ = try await session.data(for: req)
    }

    func logMeal(userId: String, name: String, calories: Int, proteinG: Int = 0, carbsG: Int = 0, fatG: Int = 0) async throws {
        var req = try request("\(kBaseURL)/log/meal", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_id": userId, "name": name, "calories": calories,
            "protein_g": proteinG, "carbs_g": carbsG, "fat_g": fatG
        ])
        _ = try await session.data(for: req)
    }

    func logWeight(userId: String, weightKg: Double) async throws -> [String: Any] {
        var req = try request("\(kBaseURL)/log/weight", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "weight_kg": weightKg])
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func logWater(userId: String, glasses: Int = 1) async throws -> Int {
        var req = try request("\(kBaseURL)/log/water", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "glasses": glasses])
        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let total = json["water_glasses_today"] as? Int { return total }
        return glasses
    }

    // MARK: - Workout Plan

    func getWorkoutPlan(userId: String, date: String? = nil) async throws -> PlannedWorkout? {
        var urlString = "\(kBaseURL)/workout-plan/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString)
        let (data, _) = try await session.data(for: req)
        return try? JSONDecoder().decode(PlannedWorkout.self, from: data)
    }

    func deleteWorkoutPlan(userId: String, date: String? = nil) async throws {
        var urlString = "\(kBaseURL)/workout-plan/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString, method: "DELETE")
        _ = try await session.data(for: req)
    }

    func generateWorkoutPlan(userId: String, date: String? = nil) async throws -> PlannedWorkout {
        var urlString = "\(kBaseURL)/workout-plan/\(userId)"
        if let date { urlString += "?date=\(date)" }
        let req = try request(urlString, method: "POST")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(PlannedWorkout.self, from: data)
    }

    func toggleExerciseComplete(userId: String, exerciseId: String, date: String? = nil) async throws {
        var urlString = "\(kBaseURL)/workout-plan/\(userId)/exercise/\(exerciseId)/complete"
        if let date { urlString += "?date=\(date)" }
        var req = try request(urlString, method: "PATCH")
        req.httpBody = Data()
        _ = try await session.data(for: req)
    }

    func logExercise(userId: String, exerciseId: String, calories: Int? = nil, date: String? = nil) async throws {
        var req = try request("\(kBaseURL)/workout-plan/\(userId)/exercise/\(exerciseId)/log", method: "POST")
        var body: [String: Any] = [:]
        if let cal = calories { body["calories_override"] = cal }
        if let d = date { body["date"] = d }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: req)
    }

    func getExerciseVideo(exerciseName: String, targetMuscles: String = "") async throws -> VideoStatus {
        let encoded = exerciseName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exerciseName
        var urlString = "\(kBaseURL)/exercise/video/\(encoded)"
        if !targetMuscles.isEmpty {
            let m = targetMuscles.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? targetMuscles
            urlString += "?target_muscles=\(m)"
        }
        let req = try request(urlString)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(VideoStatus.self, from: data)
    }

    func pollExerciseVideoStatus(jobId: String) async throws -> VideoStatus {
        let req = try request("\(kBaseURL)/exercise/video/status/\(jobId)")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(VideoStatus.self, from: data)
    }

}
