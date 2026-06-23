import { chmodSync, existsSync } from 'node:fs'
import { join } from 'node:path'

if (process.platform !== 'win32') {
  const helperPath = join(
    process.cwd(),
    'node_modules',
    'node-pty',
    'prebuilds',
    `${process.platform}-${process.arch}`,
    'spawn-helper'
  )

  if (existsSync(helperPath)) {
    chmodSync(helperPath, 0o755)
  }
}
