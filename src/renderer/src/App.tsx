import { useEffect, useRef, useState } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'

function keyEventToTerminalInput(
  event: React.KeyboardEvent<HTMLTextAreaElement>
): string | undefined {
  if (event.nativeEvent.isComposing || event.metaKey) {
    return undefined
  }

  if (event.ctrlKey && event.key.length === 1) {
    const charCode = event.key.toUpperCase().charCodeAt(0)

    if (charCode >= 64 && charCode <= 95) {
      return String.fromCharCode(charCode - 64)
    }
  }

  switch (event.key) {
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
      if (!event.ctrlKey && !event.altKey && event.key.length === 1) {
        return event.key
      }

      return undefined
  }
}

function App(): React.JSX.Element {
  const terminalElementRef = useRef<HTMLDivElement>(null)
  const inputElementRef = useRef<HTMLTextAreaElement>(null)
  const isComposingRef = useRef(false)
  const [isComposing, setIsComposing] = useState(false)

  useEffect(() => {
    const terminal = new Terminal({
      cursorBlink: true,
      fontFamily:
        'Menlo, Monaco, "Cascadia Mono", "Segoe UI Mono", "Roboto Mono", "Courier New", monospace',
      fontSize: 13,
      theme: {
        background: '#0c0f10',
        foreground: '#d8dee9',
        cursor: '#d8dee9',
        selectionBackground: '#3b4252',
        black: '#0c0f10',
        blue: '#5e81ac',
        brightBlue: '#81a1c1',
        brightWhite: '#eceff4',
        cyan: '#88c0d0',
        green: '#a3be8c',
        red: '#bf616a',
        white: '#d8dee9',
        yellow: '#ebcb8b'
      }
    })
    const fitAddon = new FitAddon()
    const terminalElement = terminalElementRef.current

    if (!terminalElement) {
      return
    }

    const focusInput = (): void => {
      inputElementRef.current?.focus()
    }

    const updateInputPosition = (): void => {
      const inputElement = inputElementRef.current
      const screenElement = terminalElement.querySelector('.xterm-screen')
      const frameElement = terminalElement.parentElement

      if (
        !inputElement ||
        !screenElement ||
        !frameElement ||
        terminal.cols === 0 ||
        terminal.rows === 0
      ) {
        return
      }

      const screenRect = screenElement.getBoundingClientRect()
      const frameRect = frameElement.getBoundingClientRect()
      const cellWidth = screenRect.width / terminal.cols
      const cellHeight = screenRect.height / terminal.rows
      const cursorX = terminal.buffer.active.cursorX
      const cursorY = terminal.buffer.active.cursorY
      const left = screenRect.left - frameRect.left + cursorX * cellWidth
      const top = screenRect.top - frameRect.top + cursorY * cellHeight
      const width = screenRect.right - frameRect.left - left

      inputElement.style.left = `${left}px`
      inputElement.style.top = `${top}px`
      inputElement.style.width = `${Math.max(width, cellWidth * 8)}px`
      inputElement.style.height = `${cellHeight}px`
      inputElement.style.lineHeight = `${cellHeight}px`
      inputElement.style.fontFamily = terminal.options.fontFamily || ''
      inputElement.style.fontSize = `${terminal.options.fontSize}px`
    }

    terminal.loadAddon(fitAddon)
    terminal.open(terminalElement)

    const fit = (): void => {
      fitAddon.fit()
      window.api.terminal.resize(terminal.cols, terminal.rows)
      updateInputPosition()
    }

    const removeDataListener = window.api.terminal.onData((data) => {
      terminal.write(data, updateInputPosition)
    })
    const handlePaste = (event: ClipboardEvent): void => {
      const text = event.clipboardData?.getData('text')

      if (!text) {
        return
      }

      event.preventDefault()
      window.api.terminal.write(text)
    }
    void window.api.terminal.start().then(() => {
      fit()
      requestAnimationFrame(focusInput)
    })

    window.addEventListener('resize', fit)
    window.addEventListener('focus', focusInput)
    window.addEventListener('paste', handlePaste)

    return () => {
      window.removeEventListener('resize', fit)
      window.removeEventListener('focus', focusInput)
      window.removeEventListener('paste', handlePaste)
      removeDataListener()
      terminal.dispose()
      window.api.terminal.dispose()
    }
  }, [])

  const handleBeforeInput = (event: React.FormEvent<HTMLTextAreaElement>): void => {
    const nativeEvent = event.nativeEvent as InputEvent

    event.preventDefault()

    if (isComposingRef.current || nativeEvent.isComposing || !nativeEvent.data) {
      return
    }

    event.currentTarget.value = ''
  }

  const handleCompositionStart = (): void => {
    isComposingRef.current = true
    setIsComposing(true)
    window.api.terminal.setComposing(true)
  }

  const handleCompositionEnd = (event: React.CompositionEvent<HTMLTextAreaElement>): void => {
    isComposingRef.current = false
    setIsComposing(false)
    window.api.terminal.setComposing(false)

    const value = event.currentTarget.value

    if (!value) {
      return
    }

    window.api.terminal.write(value)
    event.currentTarget.value = ''
  }

  const handleKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>): void => {
    const input = keyEventToTerminalInput(event)

    if (!input) {
      return
    }

    event.preventDefault()
    event.currentTarget.value = ''
  }

  const handlePointerDown = (event: React.PointerEvent<HTMLDivElement>): void => {
    event.preventDefault()
    inputElementRef.current?.focus()
  }

  return (
    <div className="terminal-frame" onPointerDownCapture={handlePointerDown}>
      <div className="terminal" ref={terminalElementRef} />
      <textarea
        ref={inputElementRef}
        className={isComposing ? 'terminal-input is-composing' : 'terminal-input'}
        autoCapitalize="off"
        autoComplete="off"
        autoCorrect="off"
        spellCheck={false}
        onBeforeInput={handleBeforeInput}
        onCompositionStart={handleCompositionStart}
        onCompositionEnd={handleCompositionEnd}
        onKeyDown={handleKeyDown}
      />
    </div>
  )
}

export default App
