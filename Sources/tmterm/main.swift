import AppKit
import SwiftTerm

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency LocalProcessTerminalViewDelegate, NSWindowDelegate {
  private let tmuxSessionName = ProcessInfo.processInfo.environment["TMTERM_TMUX_SESSION"] ?? "tmterm"
  private var config = AppConfig.load()
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
  private var scrollWheelMonitor: Any?
  private var tabRefreshTimer: Timer?
  private var tmuxExecutable: String?
  private var window: NSWindow?
  private var contentView: TerminalContainerView?
  private var terminalView: LocalProcessTerminalView?
  private var selectionWindowIndex: Int?

  func applicationDidFinishLaunching(_ notification: Notification) {
    changeCurrentDirectoryToHome()
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
    terminalView.terminal.options.cursorStyle = .steadyBar
    terminalView.cursorStyleChanged(source: terminalView.terminal, newStyle: .steadyBar)
    terminalView.caretViewTracksFocus = false
    terminalView.allowMouseReporting = false
    terminalView.onSelectionChanged = { [weak self] isActive in
      guard let self else {
        return
      }
      self.selectionWindowIndex = isActive ? self.contentView?.activeWindowIndex : nil
    }
    let contentView = TerminalContainerView(terminalView: terminalView)
    contentView.onSelectTab = { [weak self] index in
      self?.selectTmuxWindow(index: index)
    }
    contentView.onNewTab = { [weak self] in
      self?.createTmuxWindow()
    }
    contentView.onCloseTab = { [weak self] index in
      self?.closeTmuxWindow(index: index)
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 670),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = makeWindowTitle()
    window.contentView = contentView
    if let windowFrame = config.windowFrame {
      window.setFrame(windowFrame, display: false)
    } else {
      window.center()
    }
    window.makeKeyAndOrderFront(nil)
    window.delegate = self

    self.window = window
    self.contentView = contentView
    self.terminalView = terminalView

    NSApp.activate(ignoringOtherApps: true)
    setFontSize(config.fontSize ?? defaultFontSize)
    window.makeFirstResponder(terminalView)
    startTmux()
    installTabShortcutMonitor()
    installScrollWheelMonitor()
    refreshTabs(force: true)
    tabRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refreshTabs()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    saveWindowFrame()
    if let tabShortcutMonitor {
      NSEvent.removeMonitor(tabShortcutMonitor)
    }
    if let scrollWheelMonitor {
      NSEvent.removeMonitor(scrollWheelMonitor)
    }
    tabRefreshTimer?.invalidate()
    terminalView?.terminate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func windowDidMove(_ notification: Notification) {
    saveWindowFrame()
  }

  func windowDidResize(_ notification: Notification) {
    saveWindowFrame()
  }

  private func startTmux() {
    guard let terminalView, let tmuxExecutable else {
      return
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var arguments: [String] = []
    if let tmuxConfigPath = config.resolvedTmuxConfigPath() {
      arguments.append(contentsOf: ["-f", tmuxConfigPath])
    }
    arguments.append(contentsOf: [
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
    ])

    terminalView.startProcess(
      executable: tmuxExecutable,
      args: tmuxArguments(arguments),
      environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
      execName: "tmux",
      currentDirectory: home
    )
  }

  private func changeCurrentDirectoryToHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if !FileManager.default.changeCurrentDirectoryPath(home) {
      NSLog("Failed to change current directory to \(home)")
    }
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
    config.fontSize = clampedSize
    config.save()
  }

  private func saveWindowFrame() {
    guard let window else {
      return
    }

    config.windowFrame = window.frame
    config.save()
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

      if let terminalView = self.terminalView as? TmtermTerminalView,
         terminalView.handleMarkedTextKeyDown(event)
      {
        return nil
      }

      return self.handleTabShortcut(event) ? nil : event
    }
  }

  private func installScrollWheelMonitor() {
    scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard
        let self,
        self.terminalView?.window?.isKeyWindow == true,
        self.terminalView?.window?.firstResponder === self.terminalView,
        let terminalView = self.terminalView as? TmtermTerminalView
      else {
        return event
      }

      return terminalView.handleNativeScrollWheel(event) { lines in
        self.scrollTmux(lines: lines)
      } ? nil : event
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
        selectAdjacentTmuxWindowGroup(offset: -1)
        return true
      }

      if event.matchesShortcutKey("l") {
        selectAdjacentTmuxWindowGroup(offset: 1)
        return true
      }

      if event.matchesShortcutKey("j") {
        selectAdjacentTmuxWindowInGroup(offset: 1)
        return true
      }

      if event.matchesShortcutKey("k") {
        selectAdjacentTmuxWindowInGroup(offset: -1)
        return true
      }

      return forwardTabShortcutToTerminal(with: event)
    }

    if event.modifierFlags.normalized.contains(.control), event.matchesShortcutKey("w") {
      isWaitingForTabShortcut = true
      return true
    }

    return false
  }

  private func forwardTabShortcutToTerminal(with event: NSEvent) -> Bool {
    guard
      let tmuxKeyName = event.tmuxKeyName,
      let tmuxClientName = activeTmuxClientName()
    else {
      return false
    }

    if tmuxKeyName == "[" {
      terminalView?.selectNone()
    }
    runTmux(arguments: ["send-keys", "-K", "-c", tmuxClientName, "C-w", tmuxKeyName])
    return true
  }

  private func activeTmuxClientName() -> String? {
    tmuxOutput(
      arguments: [
        "list-clients",
        "-t",
        tmuxSessionName,
        "-F",
        "#{client_name}"
      ]
    )?
      .split(separator: "\n")
      .map(String.init)
      .first
  }

  private func scrollTmux(lines: Int) {
    guard lines != 0 else {
      return
    }

    terminalView?.selectNone()
    if lines > 0 {
      runTmux(arguments: ["copy-mode", "-e"])
      runTmux(arguments: ["send-keys", "-t", tmuxSessionName, "-X", "-N", "\(lines)", "scroll-up"])
    } else {
      runTmux(arguments: ["send-keys", "-t", tmuxSessionName, "-X", "-N", "\(abs(lines))", "scroll-down"])
    }
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

  private func refreshTabs(force: Bool = false) {
    guard
      let output = tmuxOutput(arguments: [
        "list-windows",
        "-t",
        tmuxSessionName,
        "-F",
        "#{window_index}\t#{window_active}\t#{window_name}\t#{pane_current_path}"
      ])
    else {
      return
    }

    let windows = output
      .split(separator: "\n")
      .compactMap { line -> TmuxWindow? in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)

        guard fields.count >= 4, let index = Int(fields[0]) else {
          return nil
        }

        return TmuxWindow(
          index: index,
          isActive: fields[1] == "1",
          name: String(fields[2]),
          currentPath: String(fields[3])
        )
      }

    if !force, terminalView?.selectionActive == true {
      if let selectionWindowIndex,
         let activeWindowIndex = windows.first(where: \.isActive)?.index,
         activeWindowIndex != selectionWindowIndex
      {
        terminalView?.selectNone()
      } else {
        return
      }
    }

    contentView?.setTabs(windows)
  }

  private func selectTmuxWindow(index: Int) {
    terminalView?.selectNone()
    runTmux(arguments: ["select-window", "-t", "\(tmuxSessionName):\(index)"])
    refreshTabs(force: true)
    terminalView?.window?.makeFirstResponder(terminalView)
  }

  private func selectAdjacentTmuxWindowGroup(offset: Int) {
    let groups = contentView?.tmuxWindowGroups ?? []
    guard
      let activeGroupPosition = groups.firstIndex(where: { group in
        group.windows.contains(where: { $0.isActive })
      }),
      !groups.isEmpty
    else {
      return
    }

    let nextGroupPosition = (activeGroupPosition + offset + groups.count) % groups.count
    guard let nextWindowIndex = contentView?.selectedWindowIndex(inGroupAt: nextGroupPosition) else {
      return
    }

    selectTmuxWindow(index: nextWindowIndex)
  }

  private func selectAdjacentTmuxWindowInGroup(offset: Int) {
    let windows = contentView?.tmuxWindows ?? []
    guard
      let activeWindow = windows.first(where: { $0.isActive }),
      let group = contentView?.tmuxWindowGroups.first(where: { group in
        group.windows.contains(where: { $0.index == activeWindow.index })
      }),
      let activePosition = group.windows.firstIndex(where: { $0.index == activeWindow.index }),
      !group.windows.isEmpty
    else {
      return
    }

    let nextPosition = (activePosition + offset + group.windows.count) % group.windows.count
    selectTmuxWindow(index: group.windows[nextPosition].index)
  }

  private func createTmuxWindow() {
    terminalView?.selectNone()
    runTmux(arguments: ["new-window", "-t", tmuxSessionName])
    refreshTabs(force: true)
    terminalView?.window?.makeFirstResponder(terminalView)
  }

  private func closeTmuxWindow(index: Int) {
    terminalView?.selectNone()
    if let nextWindowIndex = contentView?.windowIndexToSelect(afterClosing: index) {
      runTmux(arguments: ["select-window", "-t", "\(tmuxSessionName):\(nextWindowIndex)"])
    }
    runTmux(arguments: ["kill-window", "-t", "\(tmuxSessionName):\(index)"])
    refreshTabs(force: true)
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
  let currentPath: String
}

struct TmuxWindowGroup: Equatable {
  let currentPath: String
  let windows: [TmuxWindow]
}

private struct AppConfig: Codable {
  var fontSize: CGFloat?
  var tmuxConfigPath: String?
  var windowFrame: NSRect? {
    get {
      windowFrameValue?.rect
    }
    set {
      windowFrameValue = newValue.map(WindowFrameValue.init(rect:))
    }
  }

  private var windowFrameValue: WindowFrameValue?

  private enum CodingKeys: String, CodingKey {
    case fontSize
    case tmuxConfigPath
    case windowFrameValue = "windowFrame"
  }

  static func load() -> AppConfig {
    guard
      let data = try? Data(contentsOf: configURL),
      let config = try? JSONDecoder().decode(AppConfig.self, from: data)
    else {
      return AppConfig()
    }

    return config
  }

  func save() {
    do {
      try FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(self)
      try data.write(to: Self.configURL, options: .atomic)
    } catch {
      NSLog("Failed to save tmterm config: \(error)")
    }
  }

  func resolvedTmuxConfigPath() -> String? {
    guard let configuredPath = tmuxConfigPath.map(Self.expandPath) else {
      return nil
    }

    return FileManager.default.fileExists(atPath: configuredPath) ? configuredPath : nil
  }

  private static func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }

  private static var configDirectory: URL {
    if
      let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
      !xdgConfigHome.isEmpty
    {
      return URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
        .appendingPathComponent("tmterm", isDirectory: true)
    }

    return FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".config/tmterm", isDirectory: true)
  }

  private static var configURL: URL {
    configDirectory.appendingPathComponent("config.json")
  }
}

private struct WindowFrameValue: Codable {
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat
  let height: CGFloat

  init(rect: NSRect) {
    x = rect.origin.x
    y = rect.origin.y
    width = rect.size.width
    height = rect.size.height
  }

  var rect: NSRect {
    NSRect(x: x, y: y, width: width, height: height)
  }
}

final class TmtermTerminalView: LocalProcessTerminalView {
  private let markedTextView = MarkedTextOverlayView(frame: .zero)
  private var markedText: NSAttributedString?
  private var markedSelectedRange = NSRange(location: 0, length: 0)
  private var nativeCaretColorsBeforeMarkedText: (caretColor: NSColor, caretTextColor: NSColor?)?
  private var preciseScrollRemainder: CGFloat = 0
  var onSelectionChanged: ((Bool) -> Void)?

  override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
    super.cursorStyleChanged(source: source, newStyle: .steadyBar)
    updateMarkedTextViewFrame()
  }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    clearMarkedText()
    super.insertText(string, replacementRange: replacementRange)
  }

  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)

    guard let attributedText = Self.attributedString(from: string), attributedText.length > 0 else {
      clearMarkedText()
      return
    }

    markedText = attributedText
    markedSelectedRange = Self.caretRange(from: selectedRange, textLength: attributedText.length)
    hideNativeCaretForMarkedText()
    markedTextView.text = attributedText.string
    markedTextView.font = font
    markedTextView.cellSize = currentCellSize()
    markedTextView.backgroundColor = backgroundColorAtCursor()
    markedTextView.caretX = markedTextView.width(forTextUpToUTF16Offset: markedSelectedRange.location)
    markedTextView.isHidden = false

    if markedTextView.superview == nil {
      addSubview(markedTextView, positioned: .above, relativeTo: nil)
    }
    updateMarkedTextViewFrame()
  }

  func handleMarkedTextKeyDown(_ event: NSEvent) -> Bool {
    guard hasMarkedText() else {
      return false
    }

    if event.keyCode == Self.deleteKeyCode || event.isMarkedTextEditingControlKey {
      _ = inputContext?.handleEvent(event)
      return true
    }

    return false
  }

  func handleNativeScrollWheel(_ event: NSEvent, scrollAlternateScreen: (Int) -> Void) -> Bool {
    guard event.scrollingDeltaY != 0 || event.deltaY != 0 else {
      return false
    }

    if event.phase == .ended || event.momentumPhase == .ended || event.phase == .cancelled {
      preciseScrollRemainder = 0
      return true
    }

    let lines = scrollLineDelta(for: event)
    guard lines != 0 else {
      return true
    }

    if canScroll, lines > 0 {
      scrollUp(lines: lines)
    } else if canScroll {
      scrollDown(lines: abs(lines))
    } else {
      scrollAlternateScreen(lines)
    }
    return true
  }

  override func unmarkText() {
    clearMarkedText()
    super.unmarkText()
  }

  override func hasMarkedText() -> Bool {
    markedText?.length ?? 0 > 0
  }

  override func markedRange() -> NSRange {
    guard let markedText, markedText.length > 0 else {
      return NSRange(location: NSNotFound, length: 0)
    }
    return NSRange(location: 0, length: markedText.length)
  }

  override func selectedRange() -> NSRange {
    guard hasMarkedText() else {
      return super.selectedRange()
    }
    return markedSelectedRange
  }

  override func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    guard let markedText else {
      return super.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }

    let boundedRange = NSIntersectionRange(range, NSRange(location: 0, length: markedText.length))
    actualRange?.pointee = boundedRange
    guard boundedRange.length > 0 else {
      return nil
    }
    return markedText.attributedSubstring(from: boundedRange)
  }

  override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [
      .backgroundColor,
      .foregroundColor,
      .font,
      .underlineColor,
      .underlineStyle
    ]
  }

  override func layout() {
    super.layout()
    updateMarkedTextViewFrame()
  }

  override func selectionChanged(source: Terminal) {
    super.selectionChanged(source: source)
    onSelectionChanged?(selectionActive)
  }

  private func clearMarkedText() {
    markedText = nil
    markedSelectedRange = NSRange(location: 0, length: 0)
    restoreNativeCaretAfterMarkedText()
    markedTextView.text = ""
    markedTextView.caretX = 0
    markedTextView.isHidden = true
  }

  private func hideNativeCaretForMarkedText() {
    guard nativeCaretColorsBeforeMarkedText == nil else {
      return
    }

    nativeCaretColorsBeforeMarkedText = (caretColor, caretTextColor)
    caretColor = .clear
    caretTextColor = .clear
  }

  private func restoreNativeCaretAfterMarkedText() {
    guard let nativeCaretColorsBeforeMarkedText else {
      return
    }

    caretColor = nativeCaretColorsBeforeMarkedText.caretColor
    caretTextColor = nativeCaretColorsBeforeMarkedText.caretTextColor
    self.nativeCaretColorsBeforeMarkedText = nil
  }

  private func updateMarkedTextViewFrame() {
    guard markedTextView.superview != nil, !markedTextView.isHidden else {
      return
    }

    var actualRange = NSRange(location: 0, length: 0)
    let screenCaretRect = firstRect(
      forCharacterRange: markedRange(),
      actualRange: &actualRange
    )
    guard screenCaretRect != .zero, let window else {
      return
    }

    let windowCaretRect = window.convertFromScreen(screenCaretRect)
    let caretRect = convert(windowCaretRect, from: nil)
    let textSize = markedTextView.textSize
    let maxX = max(0, bounds.maxX - textSize.width)
    let x = min(maxX, max(0, caretRect.minX))
    let y = min(
      max(0, bounds.maxY - textSize.height),
      max(0, caretRect.minY)
    )

    markedTextView.frame = NSRect(
      x: x,
      y: y,
      width: textSize.width,
      height: textSize.height
    )
  }

  private func scrollLineDelta(for event: NSEvent) -> Int {
    if event.hasPreciseScrollingDeltas {
      let lineHeight = max(1, currentCellSize().height)
      preciseScrollRemainder += event.scrollingDeltaY / lineHeight
      let lines = Int(preciseScrollRemainder.rounded(.towardZero))
      preciseScrollRemainder -= CGFloat(lines)
      return lines
    }

    let delta = event.deltaY == 0 ? event.scrollingDeltaY : event.deltaY
    return Int(delta.rounded(.toNearestOrAwayFromZero))
  }

  private func currentCellSize() -> NSSize {
    guard let cellSize = cellSizeInPixels(source: terminal) else {
      return NSSize(width: font.advancement(forGlyph: font.glyph(withName: "W")).width, height: font.boundingRectForFont.height)
    }

    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    return NSSize(
      width: CGFloat(cellSize.width) / scale,
      height: CGFloat(cellSize.height) / scale
    )
  }

  private func backgroundColorAtCursor() -> NSColor {
    guard let charData = terminal.getCharData(col: terminal.buffer.x, row: terminal.buffer.y) else {
      return nativeBackgroundColor
    }

    return nsColor(forBackground: charData.attribute.bg)
  }

  private func nsColor(forBackground color: Attribute.Color) -> NSColor {
    switch color {
    case .defaultColor, .defaultInvertedColor:
      return nativeBackgroundColor
    case .ansi256(let code):
      return Self.nsColor(forAnsi256: code, defaultBackground: nativeBackgroundColor)
    case .trueColor(let red, let green, let blue):
      return NSColor(
        deviceRed: CGFloat(red) / 255.0,
        green: CGFloat(green) / 255.0,
        blue: CGFloat(blue) / 255.0,
        alpha: 1.0
      )
    }
  }

  private static func nsColor(forAnsi256 code: UInt8, defaultBackground: NSColor) -> NSColor {
    let index = Int(code)
    if index < defaultAnsiColors.count {
      return defaultAnsiColors[index]
    }

    if (16...231).contains(index) {
      let value = index - 16
      let red = value / 36
      let green = (value / 6) % 6
      let blue = value % 6
      return NSColor(
        deviceRed: CGFloat(ansiColorCubeValue(red)) / 255.0,
        green: CGFloat(ansiColorCubeValue(green)) / 255.0,
        blue: CGFloat(ansiColorCubeValue(blue)) / 255.0,
        alpha: 1.0
      )
    }

    if (232...255).contains(index) {
      let gray = CGFloat(8 + ((index - 232) * 10)) / 255.0
      return NSColor(deviceWhite: gray, alpha: 1.0)
    }

    return defaultBackground
  }

  private static func ansiColorCubeValue(_ value: Int) -> Int {
    value == 0 ? 0 : 55 + (value * 40)
  }

  private static let defaultAnsiColors = [
    nsColor(red: 9, green: 11, blue: 13),
    nsColor(red: 226, green: 92, blue: 87),
    nsColor(red: 128, green: 210, blue: 112),
    nsColor(red: 232, green: 185, blue: 85),
    nsColor(red: 102, green: 162, blue: 235),
    nsColor(red: 198, green: 128, blue: 230),
    nsColor(red: 89, green: 204, blue: 216),
    nsColor(red: 218, green: 224, blue: 232),
    nsColor(red: 112, green: 122, blue: 134),
    nsColor(red: 246, green: 113, blue: 106),
    nsColor(red: 154, green: 232, blue: 132),
    nsColor(red: 249, green: 205, blue: 105),
    nsColor(red: 125, green: 184, blue: 255),
    nsColor(red: 218, green: 154, blue: 246),
    nsColor(red: 111, green: 226, blue: 238),
    nsColor(red: 244, green: 247, blue: 250)
  ]

  private static func nsColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSColor {
    NSColor(deviceRed: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: 1.0)
  }

  private static func attributedString(from value: Any) -> NSAttributedString? {
    if let attributedString = value as? NSAttributedString {
      return attributedString
    }
    if let string = value as? NSString {
      return NSAttributedString(string: string as String)
    }
    if let string = value as? String {
      return NSAttributedString(string: string)
    }
    return nil
  }

  private static func caretRange(from selectedRange: NSRange, textLength: Int) -> NSRange {
    guard selectedRange.location != NSNotFound else {
      return NSRange(location: textLength, length: 0)
    }

    let location = min(max(0, selectedRange.location + selectedRange.length), textLength)
    return NSRange(location: location, length: 0)
  }

  private static let deleteKeyCode: UInt16 = 51
}

private final class MarkedTextOverlayView: NSView {
  var text = "" {
    didSet {
      needsDisplay = true
    }
  }
  var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  var cellSize = NSSize(width: 8, height: 16)
  var backgroundColor = NSColor.black
  var caretX: CGFloat = 0 {
    didSet {
      needsDisplay = true
    }
  }

  override var isFlipped: Bool {
    true
  }

  override var fittingSize: NSSize {
    textSize
  }

  var textSize: NSSize {
    guard !text.isEmpty else {
      return .zero
    }

    return NSSize(
      width: ceil(CGFloat(Self.columnWidth(of: text)) * cellSize.width),
      height: ceil(cellSize.height)
    )
  }

  func width(forTextUpToUTF16Offset offset: Int) -> CGFloat {
    guard offset > 0 else {
      return 0
    }

    let nsString = text as NSString
    let boundedOffset = min(offset, nsString.length)
    let prefix = nsString.substring(with: NSRange(location: 0, length: boundedOffset))
    return ceil(CGFloat(Self.columnWidth(of: prefix)) * cellSize.width)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !text.isEmpty else {
      return
    }

    backgroundColor.setFill()
    bounds.fill()

    NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.86, alpha: 0.85).setStroke()
    let underlineY = bounds.maxY - 1
    let underlineWidth = min(bounds.maxX, textSize.width)
    let underlinePath = NSBezierPath()
    underlinePath.move(to: NSPoint(x: 0, y: underlineY))
    underlinePath.line(to: NSPoint(x: underlineWidth, y: underlineY))
    underlinePath.lineWidth = 1
    underlinePath.stroke()

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 1.0)
    ]
    var x: CGFloat = 0
    for character in text.composedCharacters {
      let columnWidth = Self.columnWidth(of: character)
      let characterRect = NSRect(
        x: x,
        y: 0,
        width: CGFloat(columnWidth) * cellSize.width,
        height: bounds.height
      )
      (character as NSString).draw(in: characterRect, withAttributes: attributes)
      x += CGFloat(columnWidth) * cellSize.width
    }

    NSColor(calibratedWhite: 1.0, alpha: 1.0).setFill()
    NSRect(x: min(bounds.maxX - 1, caretX), y: 1, width: 1, height: max(0, bounds.height - 2)).fill()
  }

  private static func columnWidth(of string: String) -> Int {
    string.composedCharacters.reduce(0) { total, character in
      total + columnWidth(ofCharacter: character)
    }
  }

  private static func columnWidth(ofCharacter character: String) -> Int {
    if character.unicodeScalars.allSatisfy({ $0.properties.isJoinControl || $0.properties.generalCategory == .nonspacingMark }) {
      return 0
    }

    guard let scalar = character.unicodeScalars.first else {
      return 0
    }

    return isWide(scalar) ? 2 : 1
  }

  private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x115F,
      0x231A...0x231B,
      0x2329...0x232A,
      0x23E9...0x23EC,
      0x23F0,
      0x23F3,
      0x25FD...0x25FE,
      0x2614...0x2615,
      0x2648...0x2653,
      0x267F,
      0x2693,
      0x26A1,
      0x26AA...0x26AB,
      0x26BD...0x26BE,
      0x26C4...0x26C5,
      0x26CE,
      0x26D4,
      0x26EA,
      0x26F2...0x26F3,
      0x26F5,
      0x26FA,
      0x26FD,
      0x2705,
      0x270A...0x270B,
      0x2728,
      0x274C,
      0x274E,
      0x2753...0x2755,
      0x2757,
      0x2795...0x2797,
      0x27B0,
      0x27BF,
      0x2B1B...0x2B1C,
      0x2B50,
      0x2B55,
      0x2E80...0xA4CF,
      0xAC00...0xD7A3,
      0xF900...0xFAFF,
      0xFE10...0xFE19,
      0xFE30...0xFE6F,
      0xFF00...0xFF60,
      0xFFE0...0xFFE6,
      0x1F300...0x1FAFF,
      0x20000...0x3FFFD:
      return true
    default:
      return false
    }
  }
}

private extension String {
  var composedCharacters: [String] {
    var characters: [String] = []
    (self as NSString).enumerateSubstrings(
      in: NSRange(location: 0, length: (self as NSString).length),
      options: [.byComposedCharacterSequences]
    ) { substring, _, _, _ in
      if let substring {
        characters.append(substring)
      }
    }
    return characters
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
  var isMarkedTextEditingControlKey: Bool {
    guard modifierFlags.normalized.contains(.control) else {
      return false
    }

    return ["a", "b", "e", "f", "h"].contains { matchesShortcutKey($0) }
  }

  var tmuxKeyName: String? {
    if modifierFlags.normalized.contains(.control),
       let character = charactersIgnoringModifiers?.lowercased(),
       character.count == 1
    {
      return "C-\(character)"
    }

    guard let charactersIgnoringModifiers, !charactersIgnoringModifiers.isEmpty else {
      return nil
    }

    if charactersIgnoringModifiers == " " {
      return "Space"
    }

    return charactersIgnoringModifiers.count == 1 ? charactersIgnoringModifiers : nil
  }

  func matchesShortcutKey(_ key: String) -> Bool {
    if charactersIgnoringModifiers?.lowercased() == key {
      return true
    }

    return keyCode == Self.shortcutKeyCodes[key]
  }

  private static let shortcutKeyCodes: [String: UInt16] = [
    "h": 4,
    "j": 38,
    "k": 40,
    "l": 37,
    "w": 13
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
  private let terminalTopPadding: CGFloat = 8
  private let tabRowHeight: CGFloat = 30
  private let groupHeaderHeight: CGFloat = 22
  private let tabBarVerticalPadding: CGFloat = 8
  private var windows: [TmuxWindow] = []
  private var selectedWindowIndexByPath: [String: Int] = [:]
  var tmuxWindows: [TmuxWindow] {
    windows
  }
  var activeWindowIndex: Int? {
    windows.first(where: \.isActive)?.index
  }
  var tmuxWindowGroups: [TmuxWindowGroup] {
    makeWindowGroups(from: windows)
  }
  var onSelectTab: ((Int) -> Void)?
  var onNewTab: (() -> Void)?
  var onCloseTab: ((Int) -> Void)?

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
    let tabBarHeight = currentTabBarHeight
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
      height: max(0, bounds.height - padding - terminalTopPadding - tabBarHeight)
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let tabBarHeight = currentTabBarHeight

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
    rememberActiveWindowPositions(in: windows)
    needsLayout = true
    needsDisplay = true
    tabBar.arrangedSubviews.forEach { view in
      tabBar.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    tmuxWindowGroups.forEach { group in
      let groupStack = NSStackView()
      groupStack.orientation = .vertical
      groupStack.alignment = .leading
      groupStack.distribution = .fill
      groupStack.spacing = 0
      groupStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

      let label = TabGroupHeaderLabel(string: displayName(forCurrentPath: group.currentPath))
      label.toolTip = group.currentPath
      label.widthAnchor.constraint(equalToConstant: 136).isActive = true
      label.heightAnchor.constraint(equalToConstant: groupHeaderHeight).isActive = true
      groupStack.addArrangedSubview(label)

      group.windows.forEach { window in
        let title = window.name.isEmpty ? "\(window.index):" : "\(window.index): \(window.name)"
        let button = TabButton(title: title)
        button.isActive = window.isActive
        button.target = self
        button.action = #selector(selectTab(_:))
        button.tag = window.index
        button.closeHandler = { [weak self] index in
          self?.onCloseTab?(index)
        }
        button.widthAnchor.constraint(equalToConstant: 136).isActive = true
        button.heightAnchor.constraint(equalToConstant: tabRowHeight).isActive = true
        groupStack.addArrangedSubview(button)
      }

      tabBar.addArrangedSubview(groupStack)
    }

    let addButtonStack = NSStackView()
    addButtonStack.orientation = .vertical
    addButtonStack.alignment = .leading
    addButtonStack.distribution = .fill
    addButtonStack.spacing = 0

    let addButtonSpacer = NSView()
    addButtonSpacer.widthAnchor.constraint(equalToConstant: 36).isActive = true
    addButtonSpacer.heightAnchor.constraint(equalToConstant: groupHeaderHeight).isActive = true
    addButtonStack.addArrangedSubview(addButtonSpacer)

    let addButton = TabButton(title: "+")
    addButton.isAddButton = true
    addButton.target = self
    addButton.action = #selector(newTab)
    addButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
    addButton.heightAnchor.constraint(equalToConstant: tabRowHeight).isActive = true
    addButtonStack.addArrangedSubview(addButton)
    tabBar.addArrangedSubview(addButtonStack)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    tabBar.addArrangedSubview(spacer)
  }

  private func configureTabBar() {
    tabBar.orientation = .horizontal
    tabBar.alignment = .top
    tabBar.distribution = .fill
    tabBar.spacing = 2
    tabBar.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    addSubview(tabBar)
  }

  private var currentTabBarHeight: CGFloat {
    let maxWindowCount = max(1, tmuxWindowGroups.map(\.windows.count).max() ?? 1)
    return groupHeaderHeight + CGFloat(maxWindowCount) * tabRowHeight + tabBarVerticalPadding
  }

  private func makeWindowGroups(from windows: [TmuxWindow]) -> [TmuxWindowGroup] {
    var groups: [TmuxWindowGroup] = []

    windows.forEach { window in
      if let index = groups.firstIndex(where: { $0.currentPath == window.currentPath }) {
        var groupWindows = groups[index].windows
        groupWindows.append(window)
        groups[index] = TmuxWindowGroup(
          currentPath: window.currentPath,
          windows: groupWindows
        )
      } else {
        groups.append(TmuxWindowGroup(currentPath: window.currentPath, windows: [window]))
      }
    }

    return groups.sorted { lhs, rhs in
      let comparison = lhs.currentPath.localizedStandardCompare(rhs.currentPath)
      if comparison == .orderedSame {
        return lhs.currentPath < rhs.currentPath
      }
      return comparison == .orderedAscending
    }
  }

  private func rememberActiveWindowPositions(in windows: [TmuxWindow]) {
    windows.forEach { window in
      if window.isActive {
        selectedWindowIndexByPath[window.currentPath] = window.index
      }
    }
  }

  func selectedWindowIndex(inGroupAt position: Int) -> Int? {
    let groups = tmuxWindowGroups
    guard groups.indices.contains(position) else {
      return nil
    }

    let group = groups[position]
    if
      let rememberedIndex = selectedWindowIndexByPath[group.currentPath],
      group.windows.contains(where: { $0.index == rememberedIndex })
    {
      return rememberedIndex
    }

    return group.windows.first?.index
  }

  func windowIndexToSelect(afterClosing windowIndex: Int) -> Int? {
    guard
      let group = tmuxWindowGroups.first(where: { group in
        group.windows.contains(where: { $0.index == windowIndex })
      }),
      let closingPosition = group.windows.firstIndex(where: { $0.index == windowIndex })
    else {
      return nil
    }

    let nextPosition = closingPosition + 1
    if group.windows.indices.contains(nextPosition) {
      return group.windows[nextPosition].index
    }

    let previousPosition = closingPosition - 1
    if group.windows.indices.contains(previousPosition) {
      return group.windows[previousPosition].index
    }

    return nil
  }

  private func displayName(forCurrentPath currentPath: String) -> String {
    let url = URL(fileURLWithPath: currentPath)
    let lastPathComponent = url.lastPathComponent
    return lastPathComponent.isEmpty ? currentPath : lastPathComponent
  }

  @objc private func selectTab(_ sender: NSButton) {
    onSelectTab?(sender.tag)
  }

  @objc private func newTab() {
    onNewTab?()
  }
}

final class TabGroupHeaderLabel: NSTextField {
  init(string: String) {
    super.init(frame: .zero)
    stringValue = string
    isBezeled = false
    isBordered = false
    isEditable = false
    isSelectable = false
    drawsBackground = false
    lineBreakMode = .byTruncatingMiddle
    font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    textColor = NSColor(calibratedWhite: 0.50, alpha: 1)
    alignment = .left
    setContentHuggingPriority(.defaultHigh, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    let insetBounds = bounds.insetBy(dx: 12, dy: 4)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byTruncatingMiddle
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: textColor ?? NSColor(calibratedWhite: 0.50, alpha: 1),
      .paragraphStyle: paragraphStyle
    ]
    (stringValue as NSString).draw(in: insetBounds, withAttributes: attributes)
  }
}

final class TabButton: NSButton {
  var closeHandler: ((Int) -> Void)?
  private var isMouseInside = false {
    didSet {
      needsDisplay = true
    }
  }
  private var trackingArea: NSTrackingArea?

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

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
    }

    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    self.trackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    isMouseInside = true
  }

  override func mouseExited(with event: NSEvent) {
    isMouseInside = false
  }

  override func mouseDown(with event: NSEvent) {
    if !isAddButton, closeRect.contains(convert(event.locationInWindow, from: nil)) {
      closeHandler?(tag)
      return
    }

    super.mouseDown(with: event)
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
      NSRect(x: rect.minX + 18, y: rect.maxY - 3, width: max(0, rect.width - 44), height: 2).fill()
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = isAddButton ? .center : .left
    paragraphStyle.lineBreakMode = .byTruncatingTail

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle
    ]
    let attributedTitle = NSAttributedString(string: title, attributes: attributes)
    let titleHeight = attributedTitle.size().height
    let titleRect = NSRect(
      x: isAddButton ? 10 : 12,
      y: floor((bounds.height - titleHeight) / 2),
      width: max(0, bounds.width - (isAddButton ? 20 : 34)),
      height: titleHeight
    )
    attributedTitle.draw(in: titleRect)

    if !isAddButton, isMouseInside {
      drawCloseGlyph(in: closeRect, color: textColor)
    }
  }

  private var closeRect: NSRect {
    NSRect(x: bounds.maxX - 25, y: floor((bounds.height - 16) / 2), width: 16, height: 16)
  }

  private func drawCloseGlyph(in rect: NSRect, color: NSColor) {
    let glyphRect = rect.insetBy(dx: 4.5, dy: 4.5)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: glyphRect.minX, y: glyphRect.minY))
    path.line(to: NSPoint(x: glyphRect.maxX, y: glyphRect.maxY))
    path.move(to: NSPoint(x: glyphRect.minX, y: glyphRect.maxY))
    path.line(to: NSPoint(x: glyphRect.maxX, y: glyphRect.minY))
    color.withAlphaComponent(isHighlighted ? 0.95 : 0.70).setStroke()
    path.lineWidth = 1.35
    path.lineCapStyle = .round
    path.stroke()
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

private extension LocalProcessTerminalView {
  func applyDefaultColorScheme() {
    nativeForegroundColor = NSColor(calibratedWhite: 1.0, alpha: 1.0)
    nativeBackgroundColor = NSColor(calibratedRed: 0.035, green: 0.043, blue: 0.05, alpha: 1.0)
    caretColor = NSColor(calibratedRed: 0.46, green: 0.54, blue: 0.64, alpha: 1.0)
    caretTextColor = nativeBackgroundColor
    terminal.installPalette(colors: Self.defaultAnsiColors)
    wantsLayer = true
    layer?.backgroundColor = nativeBackgroundColor.cgColor
  }

  private static let defaultAnsiColors = [
    terminalColor(red: 9, green: 11, blue: 13),
    terminalColor(red: 226, green: 92, blue: 87),
    terminalColor(red: 128, green: 210, blue: 112),
    terminalColor(red: 232, green: 185, blue: 85),
    terminalColor(red: 102, green: 162, blue: 235),
    terminalColor(red: 198, green: 128, blue: 230),
    terminalColor(red: 89, green: 204, blue: 216),
    terminalColor(red: 218, green: 224, blue: 232),
    terminalColor(red: 112, green: 122, blue: 134),
    terminalColor(red: 246, green: 113, blue: 106),
    terminalColor(red: 154, green: 232, blue: 132),
    terminalColor(red: 249, green: 205, blue: 105),
    terminalColor(red: 125, green: 184, blue: 255),
    terminalColor(red: 218, green: 154, blue: 246),
    terminalColor(red: 111, green: 226, blue: 238),
    terminalColor(red: 244, green: 247, blue: 250)
  ]

  private static func terminalColor(red: UInt16, green: UInt16, blue: UInt16) -> Color {
    Color(red: red * 257, green: green * 257, blue: blue * 257)
  }
}
