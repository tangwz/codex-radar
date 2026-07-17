import AppKit
import SwiftUI

struct ApplicationIcon: View {
  let size: CGFloat
  let fallbackSystemImage: String

  init(size: CGFloat, fallbackSystemImage: String = "scope") {
    self.size = size
    self.fallbackSystemImage = fallbackSystemImage
  }

  var body: some View {
    Group {
      if let icon = NSApplication.shared.applicationIconImage {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: fallbackSystemImage)
          .resizable()
          .scaledToFit()
          .padding(size * 0.18)
          .foregroundStyle(Color.accentColor)
          .background(.quaternary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    .accessibilityHidden(true)
  }
}
