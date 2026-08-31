import PhotosUI
import SwiftUI

/// Editing the identity card: name, handle, photo, city, discoverability.
/// Reached from the Social tab and from Settings → My profile.
struct EditProfileView: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss

    let profile: SocialProfile

    @State private var name: String
    @State private var handle: String
    @State private var city: String
    @State private var discoverable: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var saving = false

    init(profile: SocialProfile) {
        self.profile = profile
        _name = State(initialValue: profile.displayName)
        _handle = State(initialValue: profile.handle)
        _city = State(initialValue: profile.city ?? "")
        _discoverable = State(initialValue: profile.discoverable)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AvatarView(avatarPath: social.profileState.profile?.avatarPath,
                               displayName: name, size: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Text(profile.avatarPath == nil ? "Add a photo" : "Replace photo")
                                .font(.headline)
                        }
                        if social.profileState.profile?.avatarPath != nil {
                            Button("Remove photo", role: .destructive) {
                                Task { await social.removeAvatar() }
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Photos are re-encoded on this phone before upload — scaled down and "
                     + "stripped of location and every other tag. The original never leaves.")
            }

            Section {
                TextField("Name", text: $name)
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(Theme.muted)
                    TextField("handle", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField("City or region (optional)", text: $city)
            } header: {
                Text("Identity")
            } footer: {
                Text("One name, everywhere: friends and accountability partners see the "
                     + "same one. The city is a word you type, never a location Earned asks for.")
            }

            Section {
                Toggle("Findable by handle search", isOn: $discoverable)
                    .onChange(of: discoverable) { _, value in
                        Task { await social.setDiscoverable(value) }
                    }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Off means nobody new can find you or ask to connect — "
                     + "indistinguishable from not existing. Existing friends keep you.")
            }

            if let failure = social.failure {
                Section { Text(failure).foregroundStyle(Theme.signal) }
            }

            Section {
                Button(saving ? "Saving…" : "Save changes") {
                    saving = true
                    Task {
                        let saved = await social.saveProfile(
                            handle: handle, displayName: name,
                            city: city.isEmpty ? nil : city)
                        saving = false
                        if saved { dismiss() }
                    }
                }
                .disabled(saving || !handle.isPlausibleHandle
                          || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .paperList()
        .navigationTitle("My profile")
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await social.setAvatar(pickedData: data)
                }
                photoItem = nil
            }
        }
    }
}
