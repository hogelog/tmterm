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
    terminalView.terminal.options.cursorStyle = .steadyBar
    terminalView.cursorStyleChanged(source: terminalView.terminal, newStyle: .steadyBar)
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

      if event.matchesShortcutKey("n") {
        createTmuxWindow()
        return true
      }

      return false
    }

    if event.modifierFlags.normalized.contains(.control), event.matchesShortcutKey("w") {
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
  private let markedTextView = MarkedTextOverlayView(frame: .zero)
  private var markedText: NSAttributedString?
  private var markedSelectedRange = NSRange(location: 0, length: 0)

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
    markedSelectedRange = selectedRange
    markedTextView.attributedText = Self.overlayAttributedString(from: attributedText, font: font)
    markedTextView.isHidden = false

    if markedTextView.superview == nil {
      addSubview(markedTextView, positioned: .above, relativeTo: nil)
    }
    updateMarkedTextViewFrame()
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

  private func clearMarkedText() {
    markedText = nil
    markedSelectedRange = NSRange(location: 0, length: 0)
    markedTextView.attributedText = nil
    markedTextView.isHidden = true
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
    let overlaySize = markedTextView.fittingSize
    let maxX = max(0, bounds.maxX - overlaySize.width)
    let x = min(maxX, max(0, caretRect.minX))
    let y = min(
      max(0, bounds.maxY - overlaySize.height),
      max(0, caretRect.minY)
    )

    markedTextView.frame = NSRect(
      x: x,
      y: y,
      width: overlaySize.width,
      height: overlaySize.height
    )
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

  private static func overlayAttributedString(
    from attributedString: NSAttributedString,
    font: NSFont
  ) -> NSAttributedString {
    let mutableString = NSMutableAttributedString(attributedString: attributedString)
    let fullRange = NSRange(location: 0, length: mutableString.length)
    mutableString.addAttributes(
      [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 1.0),
        .underlineColor: NSColor(calibratedWhite: 1.0, alpha: 0.9),
        .underlineStyle: NSUnderlineStyle.single.rawValue
      ],
      range: fullRange
    )
    return mutableString
  }
}

private final class MarkedTextOverlayView: NSView {
  var attributedText: NSAttributedString? {
    didSet {
      needsDisplay = true
    }
  }

  override var isFlipped: Bool {
    true
  }

  override var fittingSize: NSSize {
    guard let attributedText, attributedText.length > 0 else {
      return .zero
    }

    let textSize = attributedText.size()
    return NSSize(
      width: ceil(textSize.width),
      height: ceil(textSize.height)
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let attributedText, attributedText.length > 0 else {
      return
    }

    NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.86, alpha: 0.85).setStroke()
    let underlineY = bounds.maxY - 1
    let underlinePath = NSBezierPath()
    underlinePath.move(to: NSPoint(x: 0, y: underlineY))
    underlinePath.line(to: NSPoint(x: bounds.maxX, y: underlineY))
    underlinePath.lineWidth = 1
    underlinePath.stroke()

    let textRect = NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: attributedText.size().height
    )
    attributedText.draw(in: textRect)
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
    "h": 4,
    "l": 37,
    "n": 45,
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
      height: max(0, bounds.height - padding - terminalTopPadding - tabBarHeight)
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
