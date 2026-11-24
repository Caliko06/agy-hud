// path-preview: a file named in a reply (png, jpg, md, txt, log, json ...) gets a chip under the reply; hover it and the file opens
// in a small window by the pointer (image as is, text as its first lines); click opens it in the system's viewer. macOS only.
import type { Register, RenderElement } from 'claude-code'

import { MACOS } from './window'

const EXT = 'png|jpe?g|gif|webp|heic|md|txt|log|json|tsv|csv|html'
const PATH = new RegExp(`(?:~\\/|\\.{0,2}\\/)?[\\w.@+\\-\\/]+\\.(?:${EXT})\\b`, 'g')
const IMAGE = /\.(png|jpe?g|gif|webp|heic)$/i
const MAX_CHIPS = 6
const LIFE = 120

const files = new Map<string, string>()   // text as written (with the cwd) -> real absolute file
const targets = new Map<string, string>()        // `${requestId}/${element}` -> absolute file
let open: { file: string; isOpen: boolean } | undefined

const short = (file: string) => (file.length <= 56 ? file : `…${file.slice(-55)}`)

function close () {
  if (open) open.isOpen = false
  open = undefined
}

async function show ($: any, file: string) {
  if (open?.file === file && open.isOpen) return
  close()
  const opening = { file, isOpen: true }
  open = opening
  const env = { PATH_PREVIEW_FILE: file, PATH_PREVIEW_KIND: IMAGE.test(file) ? 'image' : 'text', PATH_PREVIEW_LIFE: String(LIFE) }
  let said = ''
  try {
    for await (const { text } of $.process.spawn({ argv: ['osascript', '-l', 'JavaScript', '-e', MACOS], env })) {
      if (said.length < 1000) said += text
      if (!opening.isOpen) break
    }
  } catch (error) {
    said += error instanceof Error ? error.message : String(error)
  }
  if (open === opening) open = undefined
  if (/error/.test(said)) $.ui.log(`path-preview: ${said.replace(/\.\n/g, '').trim().slice(0, 200)}`, { to: 'debug' })
}

/** The existing files a reply's text names, as absolute paths, each once. */
async function filesIn ($: any, text: string) {
  const home = ((await $.env.get('HOME')) as string | undefined) ?? ''
  const cwd = (await $.session.cwd()) as string
  const found: string[] = []
  for (const name of new Set(text.match(PATH) ?? [])) {
    const key = `${cwd}\n${name}`
    // Only a file found is remembered: a capture named before it is written gets its chip once it exists.
    if (!files.has(key)) {
      const abs = name.startsWith('~/') ? home + name.slice(1) : name.startsWith('/') ? name : `${cwd}/${name.replace(/^\.\//, '')}`
      if (await $.fs.exists(abs).catch(() => false)) files.set(key, abs)
    }
    const abs = files.get(key)
    if (abs && !found.includes(abs)) found.push(abs)
    if (found.length >= MAX_CHIPS) break
  }
  return found
}

export const register: Register = (on) => {
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.viewport?.isFullscreen === false) return next(e)
    const drawn: RenderElement = await next(e)
    const found = await filesIn($, e.props.text)
    if (found.length === 0) return drawn
    const { Box, Client, Text } = $.ui.resolve(e)
    found.forEach((file, i) => targets.set(`${e.requestId}/p:${i}`, file))
    return (
      <Box flexDirection="column">
        {drawn}
        <Box flexDirection="row" columnGap={1} marginLeft={2}>
          <Text dimColor>hover to preview ·</Text>
          {found.map((file, i) => <Client key={`p:${i}`} module="./chip.tsx" props={{ label: `[${short(file.replace(/^.*\//, '') === file ? file : file.replace(/^\/Users\/[^/]+/, '~'))}]` }} />)}
        </Box>
      </Box>
    )
  })

  on('ui.message', async ($, e, next) => {
    const result = await next(e)
    if (!/^p:\d+$/.test(e.element)) return result
    const file = targets.get(`${e.requestId}/${e.element}`)
    if (!file) return result
    const data = e.data as { isOver?: unknown; isClicked?: unknown } | null
    if (data?.isClicked === true) {
      close()
      void $.process.run(['open', file]).catch(() => undefined)
    } else if (data?.isOver === true) void show($, file)
    else if (open?.file === file) close()
    return result
  })

  on('prompt.submit', async ($, e, next) => {
    close()
    return next(e)
  })
}
