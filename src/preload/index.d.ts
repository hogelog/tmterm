import { ElectronAPI } from '@electron-toolkit/preload'

interface TerminalAPI {
  start: () => Promise<void>
  write: (data: string) => void
  resize: (cols: number, rows: number) => void
  dispose: () => void
  onData: (callback: (data: string) => void) => () => void
}

interface API {
  terminal: TerminalAPI
}

declare global {
  interface Window {
    electron: ElectronAPI
    api: API
  }
}
