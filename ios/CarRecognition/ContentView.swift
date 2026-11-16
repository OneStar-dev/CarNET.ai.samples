import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var model = Recognizer()
    @State private var libraryItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSettings = false
    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let photo = model.photo {
                        PhotoWithBoxes(photo: photo, cars: model.answer?.cars ?? [])
                    }
                    HStack(spacing: 8) {
                        if model.busy { ProgressView() }
                        Text(model.status)
                            .font(.headline)
                            .foregroundStyle(model.isError ? .red : .primary)
                            .accessibilityIdentifier("status")
                    }
                    ForEach(Array((model.answer?.cars ?? []).enumerated()), id: \.offset) { index, car in
                        CarRow(number: index + 1, car: car)
                    }
                    if !model.rawAnswer.isEmpty {
                        DisclosureGroup("The API's answer") {
                            Text(model.rawAnswer)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Which car is this?")
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                    .accessibilityIdentifier("settings")
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in Task { await model.recognize(image: image) } }
                    .ignoresSafeArea()
            }
            .onChange(of: libraryItem) {
                guard let item = libraryItem else { return }
                libraryItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await model.recognize(data: data)
                    }
                }
            }
            .onAppear {
                if Settings.key.isEmpty && Settings.address == CarnetClient.cloudAddress {
                    model.status = "Add your API key in Settings (top right) first."
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            if cameraAvailable {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
            PhotosPicker(selection: $libraryItem, matching: .images) { Label("Photos", systemImage: "photo") }
            Button { Task { await model.recognizeExample() } } label: { Label("Example", systemImage: "car") }
                .accessibilityIdentifier("example")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.busy)
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// The photo with a numbered box around each car.
struct PhotoWithBoxes: View {
    let photo: UIImage
    let cars: [Detection]

    var body: some View {
        Image(uiImage: photo)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geometry in
                    ForEach(Array(cars.enumerated()), id: \.offset) { index, car in
                        if let box = car.box {
                            let frame = CGRect(x: box.tlX * geometry.size.width, y: box.tlY * geometry.size.height,
                                               width: (box.brX - box.tlX) * geometry.size.width,
                                               height: (box.brY - box.tlY) * geometry.size.height)
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 3)
                                .overlay(alignment: .topLeading) {
                                    Text("\(index + 1)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .background(Color.accentColor)
                                }
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// One car: make, model and generation with years, how sure, color, angle, and close alternatives.
struct CarRow: View {
    let number: Int
    let car: Detection

    var body: some View {
        let guesses = car.guesses
        let best = guesses[0]
        var details = ["\(percent(best.probability)) sure"]
        if let color = car.color?.first { details.append(color.name) }
        if let angle = car.angle?.first { details.append("\(angle.name) view") }
        return VStack(alignment: .leading, spacing: 2) {
            (Text("\(number). \(best.name)").bold() + Text(best.years.map { "  \($0)" } ?? "").foregroundStyle(.secondary))
                .font(.title3)
            Text(details.joined(separator: " · "))
            if guesses.count > 1 {
                Text("Also possible: " + guesses.dropFirst().map { "\($0.name) (\(percent($0.probability)))" }.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("carRow")
    }

    private func percent(_ p: Double) -> String { String(format: "%g%%", (p * 1000).rounded() / 10) }
}
