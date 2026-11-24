// macOS: JavaScript for Automation (osascript -l JavaScript) draws one borderless AppKit panel by the pointer, never taking the
// focus or the pointer. PATH_PREVIEW_FILE = the file, PATH_PREVIEW_KIND = image | text, PATH_PREVIEW_LIFE = seconds at most.
// Prints `shown` once up, then `.` ten times a second; it ends when nobody reads. Window code adapted from the image-preview mod (MIT).
export const MACOS = String.raw`
ObjC.import('Cocoa')

function run () {
  const env = $.NSProcessInfo.processInfo.environment
  const read = key => { const value = env.objectForKey(key); return value.isNil() ? '' : ObjC.unwrap(value) }
  const say = text => $.NSFileHandle.fileHandleWithStandardOutput.writeData($(text + '\n').dataUsingEncoding($.NSUTF8StringEncoding))
  const file = read('PATH_PREVIEW_FILE')
  const kind = read('PATH_PREVIEW_KIND')
  $.NSApplication.sharedApplication.setActivationPolicy(1)
  const mouse = $.NSEvent.mouseLocation
  const screens = $.NSScreen.screens
  let screen = $.NSScreen.mainScreen
  for (let i = 0; i < screens.count; i++) {
    const frame = screens.objectAtIndex(i).frame
    if (mouse.x >= frame.origin.x && mouse.x < frame.origin.x + frame.size.width && mouse.y >= frame.origin.y && mouse.y < frame.origin.y + frame.size.height) screen = screens.objectAtIndex(i)
  }
  const area = screen.visibleFrame
  const pad = 8
  let width, height, content
  if (kind === 'image') {
    const image = $.NSImage.alloc.initWithContentsOfFile(file)
    if (image.isNil() || image.representations.count === 0) { say('error: cannot read the image'); return }
    const pixels = image.representations.firstObject
    width = pixels.pixelsWide / screen.backingScaleFactor
    height = pixels.pixelsHigh / screen.backingScaleFactor
    const fit = Math.min(1, 800 / Math.max(width, height), (area.size.width * 0.7) / width, (area.size.height * 0.7) / height)
    width = Math.round(width * fit)
    height = Math.round(height * fit)
    content = $.NSImageView.alloc.initWithFrame($.NSMakeRect(pad, pad, width, height))
    content.image = image
    content.imageScaling = 3
  } else {
    const raw = $.NSString.stringWithContentsOfFileEncodingError($(file), $.NSUTF8StringEncoding, $())
    if (raw.isNil()) { say('error: cannot read the text'); return }
    const lines = ObjC.unwrap(raw).split('\n').slice(0, 42).map(line => (line.length > 110 ? line.slice(0, 109) + '…' : line))
    const longest = lines.reduce((m, l) => Math.max(m, l.length), 20)
    width = Math.min(Math.round(longest * 7.2) + 8, area.size.width * 0.6)
    height = Math.min(lines.length * 15 + 8, area.size.height * 0.7)
    content = $.NSTextField.alloc.initWithFrame($.NSMakeRect(pad, pad, width, height))
    content.stringValue = $(lines.join('\n'))
    content.editable = false
    content.bordered = false
    content.drawsBackground = false
    content.textColor = $.NSColor.whiteColor
    content.font = $.NSFont.monospacedSystemFontOfSizeWeight(11.5, 0)
  }
  const outer = { width: width + pad * 2, height: height + pad * 2 }
  const gap = 18
  const top = area.origin.y + area.size.height
  const right = area.origin.x + area.size.width
  let x = mouse.x + gap
  let y = mouse.y + gap
  if (y + outer.height > top) y = mouse.y - gap - outer.height
  if (x + outer.width > right) x = mouse.x - gap - outer.width
  x = Math.max(area.origin.x, Math.min(x, right - outer.width))
  y = Math.max(area.origin.y, Math.min(y, top - outer.height))
  const panel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(x, y, outer.width, outer.height), 128, 2, false)
  panel.level = 25
  panel.ignoresMouseEvents = true
  panel.hasShadow = true
  panel.opaque = false
  panel.backgroundColor = $.NSColor.clearColor
  panel.collectionBehavior = 1 | 16 | 256
  const backdrop = $.NSVisualEffectView.alloc.initWithFrame($.NSMakeRect(0, 0, outer.width, outer.height))
  backdrop.material = 13
  backdrop.state = 1
  backdrop.wantsLayer = true
  backdrop.layer.cornerRadius = 10
  backdrop.layer.masksToBounds = true
  backdrop.addSubview(content)
  panel.contentView = backdrop
  panel.orderFrontRegardless
  say('shown')
  const end = Date.now() + (Number(read('PATH_PREVIEW_LIFE')) || 120) * 1000
  while (Date.now() < end) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1))
    say('.')
  }
}
`
