import SwiftUI
import PhotosUI

struct ScanView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var scanResult: ScanResponse?
    @State private var isScanning = false
    @State private var showCamera = false
    @State private var logged = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // Pick source
                    HStack(spacing: 16) {
                        // Gallery picker
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            SourceButton(icon: "photo.on.rectangle", label: "Gallery")
                        }
                        .onChange(of: selectedPhoto) { _, item in
                            Task { await loadPhoto(item) }
                        }

                        // Camera (unavailable on simulator)
                        Button { showCamera = true } label: {
                            SourceButton(icon: "camera.fill", label: "Camera")
                        }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    }
                    .padding(.horizontal)

                    // Preview + result
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 260)
                            .clipped()
                            .cornerRadius(16)
                            .padding(.horizontal)

                        if isScanning {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Rena is analyzing...")
                                    .font(.subheadline)
                                    .foregroundColor(Color(hex: "7C5C45"))
                            }
                            .padding()
                        } else if let result = scanResult {
                            ScanResultCard(result: result, logged: $logged) {
                                Task { await logMeal(result) }
                            }
                            .padding(.horizontal)
                        } else {
                            Button {
                                Task { await scanCurrentImage() }
                            } label: {
                                Label("Analyze this food", systemImage: "sparkles")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color(hex: "E76F51"))
                                    .cornerRadius(14)
                            }
                            .padding(.horizontal)
                        }
                    } else {
                        // Empty state
                        VStack(spacing: 16) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 64))
                                .foregroundColor(Color(hex: "D4B8A0"))
                            Text("Take a photo or pick from gallery\nto identify food and log calories")
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
            .navigationTitle("Scan Food")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showCamera) {
                CameraView(image: $selectedImage)
                    .ignoresSafeArea()
                    .onChange(of: selectedImage) { _, _ in
                        scanResult = nil
                        logged = false
                    }
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            await MainActor.run {
                selectedImage = image
                scanResult = nil
                logged = false
            }
        }
    }

    private func scanCurrentImage() async {
        guard let image = selectedImage else { return }
        await MainActor.run { isScanning = true }
        if let result = try? await RenaAPI.shared.scanImage(userId: appState.userId, image: image) {
            await MainActor.run {
                scanResult = result
                isScanning = false
            }
        } else {
            await MainActor.run { isScanning = false }
        }
    }

    private func logMeal(_ result: ScanResponse) async {
        guard let _ = try? await RenaAPI.shared.scanImage(
            userId: appState.userId,
            image: selectedImage!,
            autoLog: true
        ) else { return }
        await MainActor.run {
            logged = true
            appState.caloriesConsumed += result.totalCalories ?? 0
        }
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

struct ScanResultCard: View {
    let result: ScanResponse
    @Binding var logged: Bool
    let onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.description ?? "Food detected")
                        .font(.headline)
                        .foregroundColor(Color(hex: "3D2B1F"))
                    if let conf = result.confidence {
                        Text("Confidence: \(conf)")
                            .font(.caption)
                            .foregroundColor(Color(hex: "7C5C45"))
                    }
                }
                Spacer()
                Text("\(result.totalCalories ?? 0) cal")
                    .font(.title2.bold())
                    .foregroundColor(Color(hex: "E76F51"))
            }

            HStack(spacing: 16) {
                MacroTag(label: "Protein", value: result.totalProteinG ?? 0, color: Color(hex: "2A9D8F"))
                MacroTag(label: "Carbs", value: result.totalCarbsG ?? 0, color: Color(hex: "E9C46A"))
                MacroTag(label: "Fat", value: result.totalFatG ?? 0, color: Color(hex: "F4A261"))
            }

            Button(action: onLog) {
                Label(logged ? "Logged ✓" : "Log this meal", systemImage: logged ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(logged ? Color(hex: "2A9D8F") : Color(hex: "E76F51"))
                    .cornerRadius(14)
            }
            .disabled(logged)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
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

// MARK: - Simple Camera wrapper

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
