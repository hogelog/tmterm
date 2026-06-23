import { app, shell, BrowserWindow, ipcMain } from 'electron'
import { join } from 'path'
import { homedir } from 'os'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import { IPty, spawn } from 'node-pty'
import icon from '../../resources/icon.png?asset'

const terminalProcesses = new Map<number, IPty>()
const composingWebContents = new Set<number>()

function inputEventToTerminalInput(input: Electron.Input): string | undefined {
  if (input.type !== 'keyDown' || input.meta) {
    return undefined
  }

  if (input.control && input.key.length === 1) {
    const charCode = input.key.toUpperCase().charCodeAt(0)

    if (charCode >= 64 && charCode <= 95) {
      return String.fromCharCode(charCode - 64)
    }
  }

  switch (input.key) {
    case ' ':
      return ' '
    case 'Enter':
      return '\r'
    case 'Backspace':
      return '\x7f'
    case 'Tab':
      return '\t'
    case 'Escape':
      return '\x1b'
    case 'ArrowUp':
      return '\x1b[A'
    case 'ArrowDown':
      return '\x1b[B'
    case 'ArrowRight':
      return '\x1b[C'
    case 'ArrowLeft':
      return '\x1b[D'
    case 'Home':
      return '\x1b[H'
    case 'End':
      return '\x1b[F'
    case 'Delete':
      return '\x1b[3~'
    case 'PageUp':
      return '\x1b[5~'
    case 'PageDown':
      return '\x1b[6~'
    default:
      if (!input.control && !input.alt && input.key.length === 1) {
        return input.key
      }

      return undefined
  }
}

function getShell(): string {
  if (process.platform === 'win32') {
    return process.env['COMSPEC'] || 'powershell.exe'
  }

  return process.env['SHELL'] || '/bin/zsh'
}

function createTerminal(window: BrowserWindow): void {
  const webContentsId = window.webContents.id
  terminalProcesses.get(webContentsId)?.kill()

  const terminal = spawn(getShell(), [], {
    name: 'xterm-256color',
    cols: 80,
    rows: 24,
    cwd: homedir(),
    env: process.env
  })

  terminal.onData((data) => {
    if (!window.isDestroyed()) {
      window.webContents.send('terminal:data', data)
    }
  })

  terminal.onExit(() => {
    terminalProcesses.delete(webContentsId)
  })

  terminalProcesses.set(webContentsId, terminal)
}

function disposeTerminal(webContentsId: number): void {
  const terminal = terminalProcesses.get(webContentsId)

  if (!terminal) {
    return
  }

  terminal.kill()
  terminalProcesses.delete(webContentsId)
}

function createWindow(): void {
  // Create the browser window.
  const mainWindow = new BrowserWindow({
    width: 900,
    height: 670,
    show: false,
    autoHideMenuBar: true,
    ...(process.platform === 'linux' ? { icon } : {}),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false
    }
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow.show()
  })

  mainWindow.on('closed', () => {
    disposeTerminal(mainWindow.webContents.id)
    composingWebContents.delete(mainWindow.webContents.id)
  })

  mainWindow.webContents.on('before-input-event', (event, input) => {
    if (composingWebContents.has(mainWindow.webContents.id)) {
      return
    }

    const data = inputEventToTerminalInput(input)

    if (!data) {
      return
    }

    event.preventDefault()
    terminalProcesses.get(mainWindow.webContents.id)?.write(data)
  })

  mainWindow.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url)
    return { action: 'deny' }
  })

  // HMR for renderer base on electron-vite cli.
  // Load the remote URL for development or the local html file for production.
  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

// This method will be called when Electron has finished
// initialization and is ready to create browser windows.
// Some APIs can only be used after this event occurs.
app.whenReady().then(() => {
  // Set app user model id for windows
  electronApp.setAppUserModelId('com.electron')

  // Default open or close DevTools by F12 in development
  // and ignore CommandOrControl + R in production.
  // see https://github.com/alex8088/electron-toolkit/tree/master/packages/utils
  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  ipcMain.handle('terminal:start', (event) => {
    const window = BrowserWindow.fromWebContents(event.sender)

    if (window) {
      createTerminal(window)
    }
  })

  ipcMain.on('terminal:write', (event, data: string) => {
    terminalProcesses.get(event.sender.id)?.write(data)
  })

  ipcMain.on('terminal:resize', (event, size: { cols: number; rows: number }) => {
    const cols = Math.max(1, Math.floor(size.cols))
    const rows = Math.max(1, Math.floor(size.rows))

    terminalProcesses.get(event.sender.id)?.resize(cols, rows)
  })

  ipcMain.on('terminal:dispose', (event) => {
    disposeTerminal(event.sender.id)
  })

  ipcMain.on('terminal:composition', (event, isComposing: boolean) => {
    if (isComposing) {
      composingWebContents.add(event.sender.id)
    } else {
      composingWebContents.delete(event.sender.id)
    }
  })

  createWindow()

  app.on('activate', function () {
    // On macOS it's common to re-create a window in the app when the
    // dock icon is clicked and there are no other windows open.
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

// Quit when all windows are closed, except on macOS. There, it's common
// for applications and their menu bar to stay active until the user quits
// explicitly with Cmd + Q.
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

// In this file you can include the rest of your app's specific main process
// code. You can also put them in separate files and require them here.
