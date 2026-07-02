# tmterm

<img src="assets/tmterm.png" width="96" alt="tmterm icon">

tmterm is a native macOS terminal prototype built with SwiftTerm and tmux.

It runs a private tmux session, renders tmux windows as native tabs, and groups
tabs by their current directory.

## Requirements

- macOS
- tmux

## Shortcuts

- `C-w h` / `C-w l`: move between directory groups
- `C-w j` / `C-w k`: move within a directory group

## Configuration

Optional settings live in `~/.config/tmterm/config.json`.

- `prefix` defaults to `C-w`
- `tmuxConfigPath` overrides tmux's normal configuration loading

```json
{
  "prefix": "C-o",
  "tmuxConfigPath": "~/.config/tmux/tmterm.conf"
}
```

## Development

Development also requires:

- mise
- Swift
- Xcode Command Line Tools

Commands:

- `mise run dev`: run tmterm
- `mise run build`: build the debug executable
- `mise run app`: build a debug app bundle
