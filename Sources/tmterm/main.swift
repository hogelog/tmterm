import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
  private let defaultFontSize: CGFloat = NSFont.systemFontSize
  private let minimumFontSize: CGFloat = 8
  private let maximumFontSize: CGFloat = 32
  private var window: NSWindow?
  private var terminalView: LocalProcessTerminalView?

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureMenu()

    let terminalView = LocalProcessTerminalView(frame: .zero)
    terminalView.processDelegate = self
    terminalView.autoresizingMask = [.width, .height]
    terminalView.applyDefaultColorScheme()
    terminalView.caretViewTracksFocus = false
    let contentView = TerminalContainerView(terminalView: terminalView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 670),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "tmterm"
    window.contentView = contentView
    window.center()
    window.makeKeyAndOrderFront(nil)

    self.window = window
    self.terminalView = terminalView

    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(terminalView)
    startShell()
  }

  func applicationWillTerminate(_ notification: Notification) {
    terminalView?.terminate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func startShell() {
    guard let terminalView else {
      return
    }

    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let shellName = URL(fileURLWithPath: shell).lastPathComponent
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    terminalView.startProcess(
      executable: shell,
      args: ["-l"],
      environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
      execName: "-\(shellName)",
      currentDirectory: home
    )
  }

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    window?.title = title.isEmpty ? "tmterm" : title
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    source.feed(text: "\r\n[process exited]\r\n")
  }

  @objc private func increaseFontSize(_ sender: Any?) {
    changeFontSize(by: 1)
  }

  @objc private func decreaseFontSize(_ sender: Any?) {
    changeFontSize(by: -1)
  }

  @objc private func resetFontSize(_ sender: Any?) {
    setFontSize(defaultFontSize)
  }

  private func changeFontSize(by delta: CGFloat) {
    guard let terminalView else {
      return
    }

    setFontSize(terminalView.font.pointSize + delta)
  }

  private func setFontSize(_ size: CGFloat) {
    guard let terminalView else {
      return
    }

    let clampedSize = min(max(size, minimumFontSize), maximumFontSize)
    terminalView.font = NSFont.monospacedSystemFont(ofSize: clampedSize, weight: .regular)
    terminalView.needsDisplay = true
  }

  private func configureMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    mainMenu.addItem(viewMenuItem)

    let appMenu = NSMenu()
    appMenu.addItem(
      NSMenuItem(
        title: "Quit tmterm",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )
    appMenuItem.submenu = appMenu

    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
      NSMenuItem(
        title: "Increase Font Size",
        action: #selector(increaseFontSize(_:)),
        keyEquivalent: "+"
      )
    )
    let increaseFontSizeAlternate = NSMenuItem(
      title: "Increase Font Size",
      action: #selector(increaseFontSize(_:)),
      keyEquivalent: "="
    )
    increaseFontSizeAlternate.isAlternate = true
    viewMenu.addItem(increaseFontSizeAlternate)
    viewMenu.addItem(
      NSMenuItem(
        title: "Decrease Font Size",
        action: #selector(decreaseFontSize(_:)),
        keyEquivalent: "-"
      )
    )
    viewMenu.addItem(
      NSMenuItem(
        title: "Reset Font Size",
        action: #selector(resetFontSize(_:)),
        keyEquivalent: "0"
      )
    )
    viewMenuItem.submenu = viewMenu

    NSApp.mainMenu = mainMenu
  }
}

final class TerminalContainerView: NSView {
  private let terminalView: LocalProcessTerminalView
  private let padding: CGFloat = 8

  init(terminalView: LocalProcessTerminalView) {
    self.terminalView = terminalView
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
    addSubview(terminalView)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    terminalView.frame = bounds.insetBy(dx: padding, dy: padding)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

private extension LocalProcessTerminalView {
  func applyDefaultColorScheme() {
    nativeForegroundColor = NSColor(calibratedRed: 0.82, green: 0.85, blue: 0.88, alpha: 1.0)
    nativeBackgroundColor = NSColor(calibratedRed: 0.035, green: 0.043, blue: 0.05, alpha: 1.0)
    terminal.installPalette(colors: Self.defaultAnsiColors)
    wantsLayer = true
    layer?.backgroundColor = nativeBackgroundColor.cgColor
  }

  private static let defaultAnsiColors = [
    terminalColor(red: 9, green: 11, blue: 13),
    terminalColor(red: 209, green: 102, blue: 97),
    terminalColor(red: 135, green: 191, blue: 117),
    terminalColor(red: 218, green: 176, blue: 93),
    terminalColor(red: 112, green: 157, blue: 217),
    terminalColor(red: 184, green: 130, blue: 207),
    terminalColor(red: 103, green: 192, blue: 200),
    terminalColor(red: 196, green: 204, blue: 212),
    terminalColor(red: 93, green: 102, blue: 111),
    terminalColor(red: 229, green: 125, blue: 118),
    terminalColor(red: 158, green: 211, blue: 137),
    terminalColor(red: 235, green: 196, blue: 117),
    terminalColor(red: 137, green: 178, blue: 233),
    terminalColor(red: 203, green: 151, blue: 224),
    terminalColor(red: 126, green: 213, blue: 219),
    terminalColor(red: 224, green: 229, blue: 235)
  ]

  private static func terminalColor(red: UInt16, green: UInt16, blue: UInt16) -> Color {
    Color(red: red * 257, green: green * 257, blue: blue * 257)
  }
}
