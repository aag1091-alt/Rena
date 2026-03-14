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

    enum LogState { case idle, logged, error }

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
                        // Photo preview
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 240)
                            .clipped()
                            .cornerRadius(16)
                            .padding(.horizontal)

                        if isScanning {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Rena is analyzing your food...")
                                    .font(.subheadline)
                                    .foregroundColor(Color(hex: "7C5C45"))
                            }
                            .padding(.vertical, 24)

                        } else if let result = scanResult {
                            ScanResultCard(
                                result: result,
                                logState: $logState,
                                onLog: { Task { await logMeal(result) } },
                                onCorrect: { correction in
                                    Task { await applyCorrection(correction, original: result) }
                                }
                            )
                            .padding(.horizontal)
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
            .sheet(isPresented: $showCamera) {
                CameraView(image: $selectedImage)
                    .ignoresSafeArea()
                    .onChange(of: selectedImage) { _, img in
                        guard img != nil else { return }
                        scanResult = nil
                        logState = .idle
                        Task { await scanCurrentImage() }
                    }
            }
        }
    }

    // MARK: - Actions

    private func loadAndScan(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            selectedImage = image
            scanResult = nil
            logState = .idle
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
        }
    }

    private func logMeal(_ result: ScanResponse) async {
        guard result.identified == true else { return }
        // Re-scan with auto_log=true to log server-side
        _ = try? await RenaAPI.shared.scanImage(userId: appState.userId, image: selectedImage!, autoLog: true)
        await MainActor.run {
            logState = .logged
            appState.caloriesConsumed += result.totalCalories ?? 0
        }
    }

    private func applyCorrection(_ correction: String, original: ScanResponse) async {
        guard let description = original.description else { return }
        await MainActor.run { isScanning = true }
        let updated = try? await RenaAPI.shared.correctScan(description: description, correction: correction)
        await MainActor.run {
            if let updated {
                scanResult = updated
                logState = .idle
            }
            isScanning = false
        }
    }
}

// MARK: - Result Card

struct ScanResultCard: View {
    let result: ScanResponse
    @Binding var logState: ScanView.LogState
    let onLog: () -> Void
    let onCorrect: (String) -> Void

    @State private var showCorrection = false
    @State private var correctionText = ""
    @FocusState private var correctionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.description ?? "Food detected")
                        .font(.headline)
                        .foregroundColor(Color(hex: "3D2B1F"))
                    if let conf = result.confidence {
                        Label(conf.capitalized + " confidence", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundColor(Color(hex: "7C5C45"))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(result.totalCalories ?? 0)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "E76F51"))
                    Text("kcal")
                        .font(.caption)
                        .foregroundColor(Color(hex: "7C5C45"))
                }
            }

            // Macros
            HStack(spacing: 12) {
                MacroTag(label: "Protein", value: result.totalProteinG ?? 0, color: Color(hex: "2A9D8F"))
                MacroTag(label: "Carbs",   value: result.totalCarbsG ?? 0,  color: Color(hex: "E9C46A"))
                MacroTag(label: "Fat",     value: result.totalFatG ?? 0,    color: Color(hex: "F4A261"))
            }

            Divider()

            // Action buttons
            if logState == .logged {
                Label("Logged! Added to today's meals.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(Color(hex: "2A9D8F"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(hex: "2A9D8F").opacity(0.1))
                    .cornerRadius(12)
            } else {
                HStack(spacing: 12) {
                    // Correct button
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            showCorrection.toggle()
                        }
                        if showCorrection { correctionFocused = true }
                    } label: {
                        Label(showCorrection ? "Cancel" : "Correct it", systemImage: showCorrection ? "xmark" : "mic.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Color(hex: "E76F51"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color(hex: "E76F51").opacity(0.1))
                            .cornerRadius(12)
                    }

                    // Log button
                    Button(action: onLog) {
                        Label("Add to log", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color(hex: "E76F51"))
                            .cornerRadius(12)
                    }
                }

                // Correction input — expands inline
                if showCorrection {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Describe what's different")
                            .font(.caption.weight(.medium))
                            .foregroundColor(Color(hex: "7C5C45"))

                        TextField("e.g. \"2 samosas not 1\" or \"grilled not fried\"", text: $correctionText, axis: .vertical)
                            .font(.subheadline)
                            .padding(12)
                            .background(Color(hex: "F7F3EE"))
                            .cornerRadius(10)
                            .focused($correctionFocused)
                            .submitLabel(.done)

                        Button {
                            guard !correctionText.isEmpty else { return }
                            let c = correctionText
                            correctionText = ""
                            showCorrection = false
                            onCorrect(c)
                        } label: {
                            Text("Recalculate")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(correctionText.isEmpty ? Color.gray.opacity(0.4) : Color(hex: "E76F51"))
                                .cornerRadius(12)
                        }
                        .disabled(correctionText.isEmpty)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
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
