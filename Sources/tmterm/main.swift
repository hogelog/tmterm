import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
  private var window: NSWindow?
  private var terminalView: LocalProcessTerminalView?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let terminalView = LocalProcessTerminalView(frame: .zero)
    terminalView.processDelegate = self
    terminalView.autoresizingMask = [.width, .height]
    terminalView.configureNativeColors()
    terminalView.caretViewTracksFocus = false

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 670),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "tmterm"
    window.contentView = terminalView
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
