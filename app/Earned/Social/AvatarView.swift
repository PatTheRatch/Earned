import SwiftUI

/// An avatar, or the person's initials where there is none — the poster
/// identity degrades to typography, never to a broken-image glyph. Square
/// corners, like everything else printed here.
struct AvatarView: View {
    @EnvironmentObject private var social: SocialStore

    let avatarPath: String?
    let displayName: String
    var size: CGFloat = 44

    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.field)
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(displayName.initials)
                    .font(Theme.display(size * 0.45))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(Theme.ink.opacity(0.15), lineWidth: 1))
        .task(id: avatarPath) {
            loaded = nil
            guard let data = await social.avatarData(path: avatarPath) else { return }
            loaded = UIImage(data: data)
        }
    }
}
