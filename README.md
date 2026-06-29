# tmterm

<img src="assets/tmterm.png" width="96" alt="tmterm icon">

tmterm is a native macOS terminal prototype built with SwiftTerm and tmux.

It runs a private tmux session, renders tmux windows as native tabs, and groups
tabs by their current directory.

## Requirements

- macOS
- tmux

## Shortcuts

- `Ctrl-W h` / `Ctrl-W l`: move between directory groups
- `Ctrl-W j` / `Ctrl-W k`: move within a directory group

## Configuration

tmterm reads tmux settings from `tmuxConfigPath` in
`~/.config/tmterm/config.json` when configured. Otherwise, tmux uses its normal
configuration loading. tmterm keeps tmux's status line hidden because tmux
windows are rendered with the native tab bar.

## Development

Development also requires:

- mise
- Swift
- Xcode Command Line Tools

Commands:

- `mise run dev`: run tmterm
- `mise run build`: build the debug executable
- `mise run app`: build a debug app bundle
