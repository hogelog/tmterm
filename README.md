# tmterm

tmterm is a native macOS terminal prototype built with SwiftTerm.

## Requirements

- macOS
- Swift 5.9 or later
- Xcode Command Line Tools

## Development

Build the app:

```sh
swift build
```

Run the app:

```sh
swift run tmterm
```

tmterm opens the user's login shell in a native AppKit window using SwiftTerm's
`LocalProcessTerminalView`.
