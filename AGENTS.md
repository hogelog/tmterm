# Repository Notes

- Keep commits focused and meaningful. Do not preserve trial-and-error history.
- Do not push unless explicitly asked.
- Swift is required for development, but this repo does not manage the Swift toolchain with mise.
- UI, IME, app icon, and app-bundle behavior changes should be checked with `mise run dev` before handing off.
- App icon source assets live in `assets/`; regenerate them with `scripts/generate-app-icon.swift`.
- Keep README concise. Put contributor workflow notes here instead.
