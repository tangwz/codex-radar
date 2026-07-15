import SwiftUI

enum MenuBarThemeMode: Equatable {
  case system
  case graphiteCobalt
}

enum MenuBarForecastEmphasis: Equatable {
  case systemAccent
  case cobalt
}

enum MenuBarActionPresentation: Equatable {
  case plain
  case insetGroup
}

struct MenuBarTheme {
  let mode: MenuBarThemeMode

  init(colorScheme: ColorScheme) {
    mode = colorScheme == .dark ? .graphiteCobalt : .system
  }

  var isDarkRedesign: Bool {
    mode == .graphiteCobalt
  }

  var forecastEmphasis: MenuBarForecastEmphasis {
    isDarkRedesign ? .cobalt : .systemAccent
  }

  var actionPresentation: MenuBarActionPresentation {
    isDarkRedesign ? .insetGroup : .plain
  }

  let panelBackground = Color(red: 23.0 / 255.0, green: 27.0 / 255.0, blue: 34.0 / 255.0)
  let elevatedSurface = Color(red: 32.0 / 255.0, green: 37.0 / 255.0, blue: 45.0 / 255.0)
  let insetSurface = Color(red: 27.0 / 255.0, green: 32.0 / 255.0, blue: 40.0 / 255.0)
  let cobaltStart = Color(red: 10.0 / 255.0, green: 58.0 / 255.0, blue: 157.0 / 255.0)
  let cobaltEnd = Color(red: 8.0 / 255.0, green: 124.0 / 255.0, blue: 255.0 / 255.0)
  let darkPrimaryText = Color.white
  let darkSecondaryText = Color.white.opacity(0.68)
  let darkTertiaryText = Color.white.opacity(0.38)
  let darkHairline = Color.white.opacity(0.09)
}
