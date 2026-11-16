import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = Settings.address
    @State private var key = Settings.key
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        if showKey { TextField("API key", text: $key) } else { SecureField("API key", text: $key) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("apiKey")
                    Toggle("Show the key", isOn: $showKey)
                } header: {
                    Text("API key")
                } footer: {
                    Text("Kept in this phone's keychain. Get a free trial key at carnet.ai. Leave it empty for CarNET Server or your own server.")
                }
                Section {
                    TextField("API address", text: $address, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("apiAddress")
                    Button("Use the Cloud API") { address = CarnetClient.cloudAddress }
                } header: {
                    Text("API address")
                } footer: {
                    Text("CarNET Server: http://YOUR-SERVER:50052/detect. An app you publish should send photos to your own server, which adds the key, such as the micro website's https://YOUR-SITE/api/recognize.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Settings.address = address
                        Settings.key = key
                        dismiss()
                    }
                    .accessibilityIdentifier("done")
                }
            }
        }
    }
}
