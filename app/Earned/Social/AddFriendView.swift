import SwiftUI

/// Finding a person by handle — the only discovery there is (§5.4). No
/// contact upload, no phone or email search, no directory to browse.
struct AddFriendView: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SocialPerson] = []
    @State private var searched = false
    @State private var asked: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 2) {
                        Text("@").foregroundStyle(Theme.muted)
                        TextField("handle", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await runSearch() } }
                    }
                } footer: {
                    Text("Search finds handles that start with what you type. Ask the person "
                         + "for theirs — that's the whole discovery mechanism, on purpose.")
                }

                // A failed search used to render as "Nobody by that handle",
                // which is a lie told by an empty array: the server was never
                // reached. Said plainly instead, above the results.
                if let failure = social.failure {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Search didn't reach the server.")
                                .foregroundStyle(Theme.signal)
                            Text(failure).font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                }

                if searched {
                    Section {
                        if results.isEmpty {
                            Text(social.failure == nil
                                 ? "Nobody by that handle."
                                 : "Nothing to show — see above.")
                                .foregroundStyle(Theme.muted)
                        } else {
                            ForEach(results) { person in
                                HStack(spacing: 12) {
                                    AvatarView(avatarPath: person.avatarPath,
                                               displayName: person.displayName, size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.displayName)
                                        Text("@\(person.handle)")
                                            .font(.footnote).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    if asked.contains(person.handle) {
                                        Text("Asked").font(.footnote)
                                            .foregroundStyle(Theme.muted)
                                    } else {
                                        Button("Add") {
                                            Task {
                                                await social.sendRequest(handle: person.handle)
                                                asked.insert(person.handle)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Theme.ink)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Results")
                    }
                }
            }
            .paperList()
            .navigationTitle("Add friend")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: query) { _, _ in
                Task { await runSearch() }
            }
        }
    }

    private func runSearch() async {
        guard query.normalizedHandle.count >= 2 else {
            results = []
            searched = false
            return
        }
        results = await social.search(query: query)
        searched = true
    }
}
