# Use an AppKit status item for secondary clicks

CodexRadar uses `NSStatusItem` with a transient `NSPopover` because SwiftUI `MenuBarExtra` does not expose secondary-click handling, while the existing Menu Bar Panel is data-rich SwiftUI content rather than a command menu. The AppKit boundary owns only status-item events and popover presentation; business and view state remain in SwiftUI, and `NSMenu` should be reconsidered only if the panel is intentionally reduced to standard command items.
