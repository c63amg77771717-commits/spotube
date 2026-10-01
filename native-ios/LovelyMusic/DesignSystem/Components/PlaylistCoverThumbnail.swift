import SwiftUI

struct PlaylistCoverThumbnail: View {
    let playlist: Playlist
    var size: CGFloat = 48
    var cornerRadius: CGFloat = Theme.CornerRadius.small
    private let coverStore = PlaylistCoverStore.shared

    var body: some View {
        let cover = coverStore.cover(for: playlist)
        Group {
            if let image = cover.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url = cover.thumbnailURL {
                AsyncThumbnail(url: url, size: size, cornerRadius: cornerRadius)
            } else {
                ZStack {
                    Theme.Colors.brandGradient.opacity(0.25)
                    Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(Theme.Colors.brandGradient)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
