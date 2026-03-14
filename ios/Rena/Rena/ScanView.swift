import SwiftUI
import PhotosUI

struct ScanView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var scanResult: ScanResponse?
    @State private var isScanning = false
    @State private var showCamera = false
    @State private var logState: LogState = .idle
    // Adjustable calories per item: keyed by item name
    @State private var adjustedCalories: [String: Int] = [:]

    enum LogState { case idle, logging, logged }

    var totalAdjustedCalories: Int {
        adjustedCalories.values.reduce(0, +)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // Source buttons
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            SourceButton(icon: "photo.on.rectangle", label: "Gallery")
                        }
                        .onChange(of: selectedPhoto) { _, item in
                            Task { await loadAndScan(item) }
                        }

                        Button { showCamera = true } label: {
                            SourceButton(icon: "camera.fill", label: "Camera")
                        }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    }
                    .padding(.horizontal)

                    if let image = selectedImage {
                        // Photo preview with scanning overlay
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipped()
                            .cornerRadius(16)
                            .overlay(alignment: .topTrailing) {
                                if !isScanning {
                                    Button { resetScan() } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title2)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.black.opacity(0.5))
                                    }
                                    .padding(10)
                                }
                            }
                            .overlay {
                                if isScanning {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(.black.opacity(0.45))
                                    VStack(spacing: 12) {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .tint(.white)
                                            .scaleEffect(1.3)
                                        Text("Analyzing your food...")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .padding(.horizontal)

                        if let result = scanResult, !isScanning {
                            let items = resolvedItems(from: result)
                            if !items.isEmpty {
                                // One card per food item
                                ForEach(items) { item in
                                    ScanItemCard(
                                        item: item,
                                        adjustedCalories: Binding(
                                            get: { adjustedCalories[item.name] ?? item.calories },
                                            set: { adjustedCalories[item.name] = $0 }
                                        )
                                    )
                                    .padding(.horizontal)
                                }

                                // Total + log button
                                logFooter(items: items)
                                    .padding(.horizontal)

                            } else {
                                Text("Couldn't identify any food in this photo. Try a clearer shot.")
                                    .font(.subheadline)
                                    .foregroundColor(Color(hex: "7C5C45"))
                                    .multilineTextAlignment(.center)
                                    .padding()
                            }
                        }
                    } else {
                        // Empty state
                        VStack(spacing: 16) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 64))
                                .foregroundColor(Color(hex: "D4B8A0"))
                            Text("Take a photo or pick from gallery\nRena will identify the food and estimate calories")
                                .font(.subheadline)
                                .foregroundColor(Color(hex: "7C5C45"))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 60)
                    }

                    Spacer(minLength: 40)
                }
            }
            .background(Color(hex: "FDF6EE").ignoresSafeArea())
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.large)
            .onDisappear { resetScan() }
            .sheet(isPresented: $showCamera, onDismiss: {
                guard selectedImage != nil else { return }
                scanResult = nil
                logState = .idle
                Task { await scanCurrentImage() }
            }) {
                CameraView(image: $selectedImage)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Log footer

    @ViewBuilder
    private func logFooter(items: [ScanItem]) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Total")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color(hex: "7C5C45"))
                Spacer()
                Text("\(totalAdjustedCalories) kcal")
                    .font(.title3.bold())
                    .foregroundColor(Color(hex: "E76F51"))
            }
            .padding(.horizontal, 4)

            if logState == .logged {
                Label("All items logged!", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(Color(hex: "2A9D8F"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "2A9D8F").opacity(0.1))
                    .cornerRadius(14)
            } else {
                Button {
                    Task { await logAllItems(items) }
                } label: {
                    HStack(spacing: 8) {
                        if logState == .logging {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        }
                        Text(logState == .logging ? "Logging..." : "Add all to log")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "E76F51"))
                    .cornerRadius(14)
                }
                .disabled(logState == .logging)
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    // MARK: - Helpers

    /// Returns items from scan, falling back to a single item built from totalCalories
    /// if Gemini didn't return an items array.
    private func resolvedItems(from result: ScanResponse) -> [ScanItem] {
        if let items = result.items, !items.isEmpty { return items }
        guard result.identified == true, let cal = result.totalCalories, cal > 0 else { return [] }
        let name = result.description ?? "Food"
        return [ScanItem(
            name: name,
            calories: cal,
            proteinG: result.totalProteinG ?? 0,
            carbsG: result.totalCarbsG ?? 0,
            fatG: result.totalFatG ?? 0
        )]
    }

    // MARK: - Actions

    private func resetScan() {
        selectedImage = nil
        selectedPhoto = nil
        scanResult = nil
        logState = .idle
        isScanning = false
        adjustedCalories = [:]
    }

    private func loadAndScan(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            selectedImage = image
            scanResult = nil
            logState = .idle
            adjustedCalories = [:]
        }
        await scanCurrentImage()
    }

    private func scanCurrentImage() async {
        guard let image = selectedImage else { return }
        await MainActor.run { isScanning = true }
        let result = try? await RenaAPI.shared.scanImage(userId: appState.userId, image: image)
        await MainActor.run {
            scanResult = result
            isScanning = false
            // Seed adjusted calories from scan items
            if let items = result?.items {
                for item in items {
                    adjustedCalories[item.name] = item.calories
                }
            }
        }
    }

    private func logAllItems(_ items: [ScanItem]) async {
        await MainActor.run { logState = .logging }
        var totalLogged = 0
        for item in items {
            let cal = adjustedCalories[item.name] ?? item.calories
            try? await RenaAPI.shared.logMeal(
                userId: appState.userId,
                name: item.name,
                calories: cal,
                proteinG: item.proteinG,
                carbsG: item.carbsG,
                fatG: item.fatG
            )
            totalLogged += cal
        }
        await MainActor.run {
            logState = .logged
            appState.caloriesConsumed += totalLogged
        }
    }
}

// MARK: - Item Card with Slider

struct ScanItemCard: View {
    let item: ScanItem
    @Binding var adjustedCalories: Int

    private var sliderMin: Double { Double(max(10, item.calories / 2)) }
    private var sliderMax: Double { Double(max(100, item.calories * 2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Name + calories
            HStack(alignment: .top) {
                Text(item.name)
                    .font(.headline)
                    .foregroundColor(Color(hex: "3D2B1F"))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(adjustedCalories)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "E76F51"))
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.2), value: adjustedCalories)
                    Text("kcal")
                        .font(.caption)
                        .foregroundColor(Color(hex: "7C5C45"))
                }
            }

            // Calorie slider
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { Double(adjustedCalories) },
                        set: { adjustedCalories = Int($0.rounded() / 10) * 10 }
                    ),
                    in: sliderMin...sliderMax,
                    step: 10
                )
                .tint(Color(hex: "E76F51"))

                HStack {
                    Text("\(Int(sliderMin)) kcal")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "D4B8A0"))
                    Spacer()
                    Text("Adjust portion")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "D4B8A0"))
                    Spacer()
                    Text("\(Int(sliderMax)) kcal")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "D4B8A0"))
                }
            }

            // Macros
            HStack(spacing: 10) {
                MacroTag(label: "Protein", value: item.proteinG, color: Color(hex: "2A9D8F"))
                MacroTag(label: "Carbs",   value: item.carbsG,   color: Color(hex: "E9C46A"))
                MacroTag(label: "Fat",     value: item.fatG,     color: Color(hex: "F4A261"))
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

// MARK: - Subviews

struct SourceButton: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(Color(hex: "E76F51"))
            Text(label)
                .font(.caption.bold())
                .foregroundColor(Color(hex: "3D2B1F"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color.white)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

struct MacroTag: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)g")
                .font(.subheadline.bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(Color(hex: "7C5C45"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Camera wrapper

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
