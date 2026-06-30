# tmterm

<img src="assets/tmterm.png" width="96" alt="tmterm icon">

tmterm is a native macOS terminal prototype built with SwiftTerm and tmux.

It runs a private tmux session, renders tmux windows as native tabs, and groups
tabs by their current directory.

## Requirements

- macOS
- tmux

## Shortcuts

- `C-b h` / `C-b l`: move between directory groups
- `C-b j` / `C-b k`: move within a directory group

## Configuration

tmterm reads tmux settings from `tmuxConfigPath` in
`~/.config/tmterm/config.json` when configured. Otherwise, tmux uses its normal
configuration loading. tmterm keeps tmux's status line hidden because tmux
windows are rendered with the native tab bar.

tmterm's tab shortcut prefix defaults to tmux's default `C-b`. Configure it with
`prefix`:

```json
{
  "prefix": "C-o"
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
