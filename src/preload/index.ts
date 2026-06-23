import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

// Custom APIs for renderer
const api = {
  terminal: {
    start: (): Promise<void> => ipcRenderer.invoke('terminal:start'),
    write: (data: string): void => ipcRenderer.send('terminal:write', data),
    resize: (cols: number, rows: number): void => {
      ipcRenderer.send('terminal:resize', { cols, rows })
    },
    dispose: (): void => ipcRenderer.send('terminal:dispose'),
    onData: (callback: (data: string) => void): (() => void) => {
      const listener = (_event: Electron.IpcRendererEvent, data: string): void => callback(data)

      ipcRenderer.on('terminal:data', listener)

      return () => {
        ipcRenderer.removeListener('terminal:data', listener)
      }
    }
  }
}

// Use `contextBridge` APIs to expose Electron APIs to
// renderer only if context isolation is enabled, otherwise
// just add to the DOM global.
if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('electron', electronAPI)
    contextBridge.exposeInMainWorld('api', api)
  } catch (error) {
    console.error(error)
  }
} else {
  // @ts-ignore (define in dts)
  window.electron = electronAPI
  // @ts-ignore (define in dts)
  window.api = api
}
