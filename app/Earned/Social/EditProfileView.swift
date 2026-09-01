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
    @State private var shareStreaks: Bool
    @State private var shareOverrideUsage: Bool
    @State private var shareLastCheckin: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var saving = false

    init(profile: SocialProfile) {
        self.profile = profile
        _name = State(initialValue: profile.displayName)
        _handle = State(initialValue: profile.handle)
        _city = State(initialValue: profile.city ?? "")
        _discoverable = State(initialValue: profile.discoverable)
        _shareStreaks = State(initialValue: profile.shareStreaks)
        _shareOverrideUsage = State(initialValue: profile.shareOverrideUsage)
        _shareLastCheckin = State(initialValue: profile.shareLastCheckin)
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

            Section {
                Toggle("Share streaks with friends", isOn: $shareStreaks)
                    .onChange(of: shareStreaks) { _, value in
                        Task { await social.setSharing(shareStreaks: value) }
                    }
                Toggle("Share Override use with friends", isOn: $shareOverrideUsage)
                    .onChange(of: shareOverrideUsage) { _, value in
                        Task { await social.setSharing(shareOverrideUsage: value) }
                    }
                Toggle("Share check-ins with friends", isOn: $shareLastCheckin)
                    .onChange(of: shareLastCheckin) { _, value in
                        Task { await social.setSharing(shareLastCheckin: value) }
                    }
            } header: {
                Text("Sharing")
            } footer: {
                Text("Streaks are your commitments-kept count and commitments since your "
                     + "last Override — an Override is a route your contract contains, not "
                     + "a failing. Override sharing decides whether a shared commitment you "
                     + "override says so, or just quietly ends. Check-in sharing lets "
                     + "friends see when Earned last heard from you — whole days only, "
                     + "shown only after three quiet days, never a live status. Turning "
                     + "any of these off withdraws what it was sharing, immediately.")
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
                } else {
                    social.avatarCouldNotBeRead()
                }
                photoItem = nil
            }
        }
    }
}
