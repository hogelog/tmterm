import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
  private let tmuxSessionName = ProcessInfo.processInfo.environment["TMTERM_TMUX_SESSION"] ?? "tmterm"
  private lazy var tmuxSocketPath: String = {
    let directory = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/tmterm", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(tmuxSessionName.socketSafeName).sock").path
  }()
  private let defaultFontSize: CGFloat = NSFont.systemFontSize
  private let minimumFontSize: CGFloat = 8
  private let maximumFontSize: CGFloat = 32
  private var isWaitingForTabShortcut = false
  private var tabShortcutMonitor: Any?
  private var tabRefreshTimer: Timer?
  private var tmuxExecutable: String?
  private var window: NSWindow?
  private var contentView: TerminalContainerView?
  private var terminalView: LocalProcessTerminalView?

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureMenu()

    guard let tmuxExecutable = findTmuxExecutable() else {
      showMissingTmuxAlert()
      NSApp.terminate(nil)
      return
    }
    self.tmuxExecutable = tmuxExecutable

    let terminalView = TmtermTerminalView(frame: .zero)
    terminalView.processDelegate = self
    terminalView.autoresizingMask = [.width, .height]
    terminalView.applyDefaultColorScheme()
    terminalView.terminal.options.cursorStyle = .steadyBlock
    terminalView.cursorStyleChanged(source: terminalView.terminal, newStyle: .steadyBlock)
    terminalView.caretViewTracksFocus = false
    let contentView = TerminalContainerView(terminalView: terminalView)
    contentView.onSelectTab = { [weak self] index in
      self?.selectTmuxWindow(index: index)
    }
    contentView.onNewTab = { [weak self] in
      self?.createTmuxWindow()
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 670),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = makeWindowTitle()
    window.contentView = contentView
    window.center()
    window.makeKeyAndOrderFront(nil)

    self.window = window
    self.contentView = contentView
    self.terminalView = terminalView

    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(terminalView)
    startTmux()
    installTabShortcutMonitor()
    refreshTabs()
    tabRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.refreshTabs()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let tabShortcutMonitor {
      NSEvent.removeMonitor(tabShortcutMonitor)
    }
    tabRefreshTimer?.invalidate()
    terminalView?.terminate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func startTmux() {
    guard let terminalView, let tmuxExecutable else {
      return
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path

    terminalView.startProcess(
      executable: tmuxExecutable,
      args: tmuxArguments([
        "-f",
        "/dev/null",
        "new-session",
        "-A",
        "-s",
        tmuxSessionName,
        ";",
        "set-option",
        "-t",
        tmuxSessionName,
        "status",
        "off"
      ]),
      environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
      execName: "tmux",
      currentDirectory: home
    )
  }

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    window?.title = makeWindowTitle(terminalTitle: title)
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    DispatchQueue.main.async {
      NSApp.terminate(nil)
    }
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

  private func makeWindowTitle(terminalTitle: String? = nil) -> String {
    let baseTitle = terminalTitle?.isEmpty == false ? terminalTitle! : "tmterm"
    return "\(baseTitle) \(windowTitleSuffix)"
  }

  private var windowTitleSuffix: String {
    var components: [String] = []

    if tmuxSessionName != "tmterm" {
      components.append("Dev")
    }

    components.append(Self.buildConfigurationName)
    return "[\(components.joined(separator: ", "))]"
  }

  private static var buildConfigurationName: String {
    #if DEBUG
      "Debug"
    #else
      "Release"
    #endif
  }

  private func installTabShortcutMonitor() {
    tabShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else {
        return event
      }

      return self.handleTabShortcut(event) ? nil : event
    }
  }

  private func handleTabShortcut(_ event: NSEvent) -> Bool {
    guard
      terminalView?.window?.isKeyWindow == true,
      terminalView?.window?.firstResponder === terminalView
    else {
      isWaitingForTabShortcut = false
      return false
    }

    if isWaitingForTabShortcut {
      isWaitingForTabShortcut = false

      if event.matchesShortcutKey("h") {
        selectAdjacentTmuxWindow(offset: -1)
        return true
      }

      if event.matchesShortcutKey("l") {
        selectAdjacentTmuxWindow(offset: 1)
        return true
      }

      if event.matchesShortcutKey("c") {
        createTmuxWindow()
        return true
      }

      return false
    }

    if event.modifierFlags.normalized.contains(.control), event.matchesShortcutKey("e") {
      isWaitingForTabShortcut = true
      return true
    }

    return false
  }

  private func findTmuxExecutable() -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let candidates = path.split(separator: ":").map { String($0) + "/tmux" } + [
      "/opt/homebrew/bin/tmux",
      "/usr/local/bin/tmux",
      "/usr/bin/tmux"
    ]

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func showMissingTmuxAlert() {
    let alert = NSAlert()
    alert.messageText = "tmux is required"
    alert.informativeText = "Install tmux and relaunch tmterm."
    alert.alertStyle = .critical
    alert.runModal()
  }

  private func tmuxOutput(arguments: [String]) -> String? {
    guard let tmuxExecutable else {
      return nil
    }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tmuxExecutable)
    process.arguments = tmuxArguments(arguments)
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }

    guard process.terminationStatus == 0 else {
      return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  private func runTmux(arguments: [String]) {
    _ = tmuxOutput(arguments: arguments)
  }

  private func tmuxArguments(_ arguments: [String]) -> [String] {
    ["-S", tmuxSocketPath] + arguments
  }

  private func refreshTabs() {
    guard
      let output = tmuxOutput(arguments: [
        "list-windows",
        "-t",
        tmuxSessionName,
        "-F",
        "#{window_index}\t#{window_active}\t#{window_name}"
      ])
    else {
      return
    }

    let windows = output
      .split(separator: "\n")
      .compactMap { line -> TmuxWindow? in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)

        guard fields.count >= 3, let index = Int(fields[0]) else {
          return nil
        }

        return TmuxWindow(index: index, isActive: fields[1] == "1", name: String(fields[2]))
      }

    contentView?.setTabs(windows)
  }

  private func selectTmuxWindow(index: Int) {
    runTmux(arguments: ["select-window", "-t", "\(tmuxSessionName):\(index)"])
    refreshTabs()
    terminalView?.window?.makeFirstResponder(terminalView)
  }

  private func selectAdjacentTmuxWindow(offset: Int) {
    let windows = contentView?.tmuxWindows ?? []
    guard
      let activePosition = windows.firstIndex(where: { $0.isActive }),
      !windows.isEmpty
    else {
      return
    }

    let nextPosition = (activePosition + offset + windows.count) % windows.count
    selectTmuxWindow(index: windows[nextPosition].index)
  }

  private func createTmuxWindow() {
    runTmux(arguments: ["new-window", "-t", tmuxSessionName])
    refreshTabs()
    terminalView?.window?.makeFirstResponder(terminalView)
  }

  private func configureMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let editMenuItem = NSMenuItem()
    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    mainMenu.addItem(editMenuItem)
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

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
      NSMenuItem(
        title: "Copy",
        action: #selector(NSText.copy(_:)),
        keyEquivalent: "c"
      )
    )
    editMenu.addItem(
      NSMenuItem(
        title: "Paste",
        action: #selector(NSText.paste(_:)),
        keyEquivalent: "v"
      )
    )
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(
      NSMenuItem(
        title: "Select All",
        action: #selector(NSText.selectAll(_:)),
        keyEquivalent: "a"
      )
    )
    editMenuItem.submenu = editMenu

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

struct TmuxWindow: Equatable {
  let index: Int
  let isActive: Bool
  let name: String
}

final class TmtermTerminalView: LocalProcessTerminalView {
  override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
    super.cursorStyleChanged(source: source, newStyle: newStyle.steady)
  }
}

private extension CursorStyle {
  var steady: CursorStyle {
    switch self {
    case .blinkBlock, .steadyBlock:
      return .steadyBlock
    case .blinkUnderline, .steadyUnderline:
      return .steadyUnderline
    case .blinkBar, .steadyBar:
      return .steadyBar
    }
  }
}

private extension String {
  var socketSafeName: String {
    map { character in
      character.isLetter || character.isNumber || character == "-" || character == "_"
        ? String(character)
        : "-"
    }.joined()
  }
}

private extension NSEvent {
  func matchesShortcutKey(_ key: String) -> Bool {
    if charactersIgnoringModifiers?.lowercased() == key {
      return true
    }

    return keyCode == Self.shortcutKeyCodes[key]
  }

  private static let shortcutKeyCodes: [String: UInt16] = [
    "c": 8,
    "e": 14,
    "h": 4,
    "l": 37
  ]
}

private extension NSEvent.ModifierFlags {
  var normalized: NSEvent.ModifierFlags {
    intersection(.deviceIndependentFlagsMask)
  }
}

final class TerminalContainerView: NSView {
  private let terminalView: LocalProcessTerminalView
  private let tabBar = NSStackView()
  private let padding: CGFloat = 8
  private let tabBarHeight: CGFloat = 34
  private var windows: [TmuxWindow] = []
  var tmuxWindows: [TmuxWindow] {
    windows
  }
  var onSelectTab: ((Int) -> Void)?
  var onNewTab: (() -> Void)?

  init(terminalView: LocalProcessTerminalView) {
    self.terminalView = terminalView
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
    addSubview(terminalView)
    configureTabBar()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    tabBar.frame = NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: tabBarHeight
    )
    terminalView.frame = NSRect(
      x: padding,
      y: tabBarHeight + padding,
      width: max(0, bounds.width - padding * 2),
      height: max(0, bounds.height - padding - tabBarHeight)
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    NSColor(calibratedRed: 0.070, green: 0.079, blue: 0.090, alpha: 1).setFill()
    NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: tabBarHeight
    ).fill()

    let separatorY = tabBarHeight
    NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.20, alpha: 1).setStroke()
    let separator = NSBezierPath()
    separator.move(to: NSPoint(x: 0, y: separatorY + 0.5))
    separator.line(to: NSPoint(x: bounds.width, y: separatorY + 0.5))
    separator.lineWidth = 1
    separator.stroke()
  }

  func setTabs(_ windows: [TmuxWindow]) {
    guard self.windows != windows else {
      return
    }

    self.windows = windows
    tabBar.arrangedSubviews.forEach { view in
      tabBar.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    windows.forEach { window in
      let title = window.name.isEmpty ? "\(window.index + 1)" : "\(window.index + 1)  \(window.name)"
      let button = TabButton(title: title)
      button.isActive = window.isActive
      button.target = self
      button.action = #selector(selectTab(_:))
      button.tag = window.index
      button.widthAnchor.constraint(equalToConstant: 128).isActive = true
      tabBar.addArrangedSubview(button)
    }

    let addButton = TabButton(title: "+")
    addButton.isAddButton = true
    addButton.target = self
    addButton.action = #selector(newTab)
    addButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
    tabBar.addArrangedSubview(addButton)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    tabBar.addArrangedSubview(spacer)
  }

  private func configureTabBar() {
    tabBar.orientation = .horizontal
    tabBar.alignment = .centerY
    tabBar.distribution = .fill
    tabBar.spacing = 2
    tabBar.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    addSubview(tabBar)
  }

  @objc private func selectTab(_ sender: NSButton) {
    onSelectTab?(sender.tag)
  }

  @objc private func newTab() {
    onNewTab?()
  }
}

final class TabButton: NSButton {
  var isActive = false {
    didSet {
      needsDisplay = true
    }
  }

  var isAddButton = false {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }

  override var intrinsicContentSize: NSSize {
    if isAddButton {
      return NSSize(width: 34, height: 26)
    }

    return NSSize(width: 128, height: 26)
  }

  init(title: String) {
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    font = NSFont.systemFont(ofSize: 12, weight: .medium)
    setButtonType(.momentaryChange)
    focusRingType = .none
    setContentHuggingPriority(.defaultHigh, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 3), xRadius: 4, yRadius: 4)

    let fillColor: NSColor
    let strokeColor: NSColor
    let textColor: NSColor

    if isActive {
      fillColor = NSColor(calibratedRed: 0.12, green: 0.135, blue: 0.155, alpha: 1)
      strokeColor = NSColor.clear
      textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
    } else if isHighlighted {
      fillColor = NSColor(calibratedRed: 0.10, green: 0.112, blue: 0.128, alpha: 1)
      strokeColor = NSColor.clear
      textColor = NSColor(calibratedWhite: 0.80, alpha: 1)
    } else {
      fillColor = NSColor.clear
      strokeColor = NSColor.clear
      textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
    }

    fillColor.setFill()
    path.fill()
    if strokeColor.alphaComponent > 0 {
      strokeColor.setStroke()
      path.lineWidth = 1
      path.stroke()
    }

    if isActive {
      NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.86, alpha: 1).setFill()
      NSRect(x: rect.minX + 18, y: rect.maxY - 3, width: max(0, rect.width - 36), height: 2).fill()
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byTruncatingTail

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle
    ]
    let attributedTitle = NSAttributedString(string: title, attributes: attributes)
    let titleHeight = attributedTitle.size().height
    let titleRect = NSRect(
      x: 10,
      y: floor((bounds.height - titleHeight) / 2),
      width: max(0, bounds.width - 20),
      height: titleHeight
    )
    attributedTitle.draw(in: titleRect)
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
    caretColor = NSColor(calibratedRed: 0.46, green: 0.54, blue: 0.64, alpha: 1.0)
    caretTextColor = nativeBackgroundColor
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
