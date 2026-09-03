import PhotosUI
import SwiftUI

/// The short walk from a fresh sign-in to an Earned identity: name, handle,
/// optional photo, optional city, done. One decision per screen, like every
/// other flow here — and deliberately nothing else is asked. No birthday, no
/// location permission, no questionnaire (docs/social-architecture.md §4.4).
struct ProfileSetupView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss

    private enum Page: Int, CaseIterable {
        case name, handle, photo, city, welcome
    }

    @State private var page: Page = .name
    @State private var name = ""
    @State private var handle = ""
    @State private var city = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoFailure: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content
            Spacer()
            controls
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
        .interactiveDismissDisabled(page == .welcome)
        .onAppear {
            // Apple offers the name exactly once, at first authorization;
            // whatever was kept then is the prefill, and it stays editable.
            if case .signedIn(let displayName) = account.session, name.isEmpty {
                // "Someone" is no longer produced anywhere (migration 0024),
                // but an account created before that fix still carries it, and
                // prefilling the field with it would launder the placeholder
                // into a name the user appears to have chosen.
                name = displayName == "Someone" ? "" : displayName
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .name:
            step(title: "YOUR NAME",
                 note: "The name your people know you by. It's what accountability "
                     + "partners and friends both see — there is only one of it.") {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.blocker(22))
                    .padding(14)
                    .background(Theme.field)
            }

        case .handle:
            step(title: "YOUR HANDLE",
                 note: "How friends find you. Lowercase letters, numbers and underscores — "
                     + "3 to 20 of them. Yours for as long as you keep it.") {
                HStack(spacing: 2) {
                    Text("@").font(Theme.blocker(22)).foregroundStyle(Theme.muted)
                    TextField("handle", text: $handle)
                        .textFieldStyle(.plain)
                        .font(Theme.blocker(22))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(14)
                .background(Theme.field)
                if let failure = social.failure {
                    Text(failure).font(.footnote).foregroundStyle(Theme.signal)
                }
            }

        case .photo:
            step(title: "YOUR PHOTO",
                 note: "Optional. It's re-encoded on this phone before upload — scaled down, "
                     + "stripped of location and every other tag. The original never leaves.") {
                HStack(spacing: 16) {
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 96, height: 96).clipped()
                    } else {
                        ZStack {
                            Rectangle().fill(Theme.field)
                            Text(name.initials)
                                .font(Theme.display(40)).foregroundStyle(Theme.muted)
                        }
                        .frame(width: 96, height: 96)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text(photoData == nil ? "Choose a photo" : "Choose another")
                            .font(.headline)
                    }
                }
                if let failure = photoFailure {
                    Text(failure).font(.footnote).foregroundStyle(Theme.signal)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    // An iCloud original that will not download fails here, and
                    // a `try?` alone would leave the placeholder sitting there
                    // looking like a tap that missed.
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        photoData = data
                        photoFailure = nil
                    } else {
                        photoFailure = "That photo couldn't be read — it may still be in "
                            + "iCloud. Try one that's on the phone, or skip this."
                    }
                }
            }

        case .city:
            step(title: "WHERE ARE YOU?",
                 note: "Optional, and just a word — London, Chicago, Grenoble. Typed, not "
                     + "tracked: Earned never asks for your location. Friends see it; "
                     + "nobody else does.") {
                TextField("City or region", text: $city)
                    .textFieldStyle(.plain)
                    .font(Theme.blocker(22))
                    .padding(14)
                    .background(Theme.field)
            }

        case .welcome:
            VStack(alignment: .leading, spacing: 18) {
                Text("WELCOME TO EARNED")
                    .font(Theme.display(44))
                    .foregroundStyle(Theme.ink)
                + Text(".").font(Theme.display(44)).foregroundStyle(Theme.signal)
                Text("@\(handle.normalizedHandle) · \(name.trimmingCharacters(in: .whitespaces))")
                    .font(Theme.blocker())
                Text("Your commitments stay yours. What friends see is what you choose to "
                     + "share — starting with nothing.")
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func step<Content: View>(title: String, note: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(Theme.display(40)).foregroundStyle(Theme.ink)
            Text(note).foregroundStyle(Theme.muted)
            content()
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            if page != .name && page != .welcome {
                Button("Back") {
                    withAnimation { page = Page(rawValue: page.rawValue - 1) ?? .name }
                }
                .font(.headline)
                .padding(.vertical, 16).padding(.horizontal, 20)
            }
            Button(buttonTitle) { advance() }
                .buttonStyle(PosterButtonStyle())
                .disabled(!canAdvance || saving)
        }
    }

    private var buttonTitle: String {
        switch page {
        case .name: return "NEXT"
        case .handle: return "NEXT"
        case .photo: return photoData == nil ? "SKIP" : "NEXT"
        case .city: return saving ? "SAVING…" : (city.isEmpty ? "SKIP AND FINISH" : "FINISH")
        case .welcome: return "DONE"
        }
    }

    private var canAdvance: Bool {
        switch page {
        case .name: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .handle: return handle.isPlausibleHandle
        case .photo, .city, .welcome: return true
        }
    }

    private func advance() {
        switch page {
        case .name, .photo:
            withAnimation { page = Page(rawValue: page.rawValue + 1) ?? .welcome }
        case .handle:
            // The server is the authority on uniqueness and reserved names;
            // moving on happens only once it has said yes to this handle.
            saving = true
            Task {
                let saved = await social.saveProfile(handle: handle, displayName: name,
                                                     city: nil)
                saving = false
                if saved { withAnimation { page = .photo } }
            }
        case .city:
            saving = true
            Task {
                let saved = await social.saveProfile(handle: handle, displayName: name,
                                                     city: city.isEmpty ? nil : city)
                if saved, let photoData {
                    await social.setAvatar(pickedData: photoData)
                }
                saving = false
                if saved { withAnimation { page = .welcome } }
            }
        case .welcome:
            dismiss()
        }
    }
}
