// Drive the DSH native folder-picker worker directly, bypassing Electron,
// to see how far the Win32 COM dialog machinery gets on Windows 7.
const { spawn } = require('node:child_process')

const NODE = 'C:\\dsh\\node24-off\\node.exe'
const WORKER =
  'C:\\Users\\ye\\AppData\\Local\\Programs\\DSH Desktop\\resources\\app\\node_modules\\@deepseek-ai\\dsh-host-directory-picker-native\\lib\\worker.cjs'

console.log('node      :', process.version, process.execPath)
console.log('worker    :', WORKER)
console.log('SSH?      :', !!(process.env.SSH_CONNECTION || process.env.SSH_CLIENT))

let sawShowing = false
const child = spawn(NODE, [WORKER], {
  env: { ...process.env, DSH_DIALOG_TITLE: 'DSH Picker Probe' },
  stdio: ['ignore', 'inherit', 'inherit', 'ipc'],
  windowsHide: true
})

child.on('message', (m) => {
  console.log('MESSAGE   :', JSON.stringify(m))
  if (m.kind === 'showing') sawShowing = true
  if (m.kind !== 'showing') {
    try { child.kill() } catch {}
  }
})
child.on('error', (e) => console.log('SPAWN ERR :', e && e.message))
child.on('exit', (code, sig) => {
  console.log('EXIT      :', code, sig)
  console.log('RESULT    :', sawShowing ? 'COM dialog created and reached Show()' : 'never reached Show()')
  process.exit(0)
})

setTimeout(() => {
  console.log('--- 6s elapsed, killing worker ---')
  console.log('RESULT    :', sawShowing ? 'COM dialog created and reached Show()' : 'no showing message -> failed before Show()')
  try { child.kill() } catch {}
  setTimeout(() => process.exit(0), 300)
}, 6000)
