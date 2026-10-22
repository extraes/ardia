import AppKit

public enum WindowHost {
  public static var makeWindow: (() -> NSWindow)?
  public static var makeContentView: ((_ windowId: String) -> NSView)?
}

final class WindowManager: NSObject, NSWindowDelegate {
  static let shared = WindowManager()

  private(set) var windows: [String: NSWindow] = [:]
  var emit: ((String, [String: Any]) -> Void)?
  private var closingFromJS = Set<String>()
  private weak var lastPlaced: NSWindow?
  private var legacyFrame = UserDefaults.standard.string(forKey: "NSWindow Frame BrowserWindow")
  private(set) var auxKinds: [String: String] = [:]
  private(set) var smallIds = Set<String>()

  private func isBrowserWindow(_ window: NSWindow?) -> Bool {
    guard let id = id(of: window) else { return false }
    return auxKinds[id] == nil
  }

  private func isMainWindow(_ window: NSWindow?) -> Bool {
    guard let id = id(of: window) else { return false }
    return auxKinds[id] == nil && !smallIds.contains(id)
  }

  func id(of window: NSWindow?) -> String? {
    guard let window else { return nil }
    return windows.first { $0.value === window }?.key
  }

  var keyWindowId: String? { id(of: NSApp.keyWindow) ?? id(of: NSApp.mainWindow) }

  func closeForeignKeyWindow() -> Bool {
    guard keyWindowId == nil, let key = NSApp.keyWindow, !(key is NSPanel), key.styleMask.contains(.closable)
    else { return false }
    key.performClose(nil)
    return true
  }

  var keyBrowserWindow: NSWindow? { keyWindowId.flatMap { windows[$0] } }

  var closableWindow: NSWindow? {
    [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { $0.styleMask.contains(.closable) }
  }

  func toggleKeepOnTop() {
    guard let window = keyBrowserWindow else { return }
    window.level = window.level == .floating ? .normal : .floating
  }

  private struct PendingOpen {
    var frame: [Double]?, incognito: Bool, title: String, kind: String, profile: String?, size: [Double]?, behind: String
    var chromeWindow: String?
    var claim: String?
  }
  private var pendingOpens: [String: PendingOpen] = [:]
  private var pendingOrder: [String] = []
  private var contentShown = Set<String>()
  private var firstContentObservers: [String: NSObjectProtocol] = [:]
  private static let behindTimeout = 1.5

  func open(
    id: String, frame: [Double]?, incognito: Bool, title: String, focus: Bool, kind: String = "browser", profile: String? = nil,
    size: [Double]? = nil, behind: String? = nil, chromeWindow: String? = nil, claim: String? = nil
  ) {
    if let existing = windows[id] {
      if focus { existing.makeKeyAndOrderFront(nil) }
      return
    }
    if let behind, !focus, windows[behind] != nil, !contentShown.contains(behind) {
      if pendingOpens[id] == nil { pendingOrder.append(id) }
      pendingOpens[id] = PendingOpen(
        frame: frame, incognito: incognito, title: title, kind: kind, profile: profile, size: size, behind: behind, chromeWindow: chromeWindow,
        claim: claim)
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.behindTimeout) { [weak self] in self?.openPending(behind: behind) }
      return
    }
    let small = kind == "small"
    if kind != "browser" && !small { return openAux(id: id, kind: kind, title: title) }
    guard let makeWindow = WindowHost.makeWindow, let makeContentView = WindowHost.makeContentView else { return }
    if !small, ChromeWindows.takeDismissed(appWindow: id) {
      emit?("onWindowEvent", ["type": "close", "id": id])
      return
    }
    if small, let claim, ChromeWindows.takeDismissed(appWindow: claim) {
      emit?("onWindowEvent", ["type": "close", "id": id])
      return
    }
    if small { smallIds.insert(id) }
    if let chromeWindow = ChromeWindows.makeWindow(profile: profile, chromeWindow: small ? nil : chromeWindow, appWindow: small ? claim : id) {
      if incognito { chromeWindow.appearance = NSAppearance(named: .darkAqua) }
      let root = makeContentView(id)
      ChromeWindows.embed(root, in: chromeWindow)
      holdUntilContent(chromeWindow, id: id, root: root)
      noteFirstContent(id: id, root: root)
      keepContentSizedAcrossReloads(id: id, root: root)
      ChromeWindows.onSwap { [weak self] from, to in self?.adopt(from: from, to: to) }
      observeDelegateNotifications(chromeWindow)
      if small { configureSmall(chromeWindow) }
      return show(chromeWindow, id: id, frame: frame, title: title, focus: focus, smallSize: small ? size ?? [] : nil, behind: behind)
    }
    let window = makeWindow()
    let controller = NSViewController()
    controller.view = makeContentView(id)
    controller.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
    window.contentViewController = controller
    window.delegate = self
    if incognito { window.appearance = NSAppearance(named: .darkAqua) }
    if small { configureSmall(window) }
    show(window, id: id, frame: frame, title: title, focus: focus, smallSize: small ? size ?? [] : nil)
  }

  private func show(_ window: NSWindow, id: String, frame: [Double]?, title: String, focus: Bool, smallSize: [Double]? = nil, behind: String? = nil) {
    window.title = title
    if let smallSize { placeSmall(window, size: smallSize) } else if frame != nil || !window.isVisible { place(window, frame: frame) }
    relayoutRoot(window)
    windows[id] = window
    if let center = lightsCenters[id] { ChromeWindows.setTrafficLightsCenter(center, in: window) }
    if smallSize == nil { lastPlaced = window }
    if window.isMiniaturized {
      observeFrame(window)
      return reportFrame(window)
    }
    if focus, unrevealed[id] != nil {
      window.orderFront(nil)
      keyOnReveal = window
      holdTyping(in: window)
      unrevealed[id]!.append { [weak self, weak window] in
        guard let self, let window, self.windows[id] === window, self.keyOnReveal === window else { return }
        self.keyOnReveal = nil
        window.makeKeyAndOrderFront(nil)
        self.typeAheadKeyed(window)
      }
    } else if focus {
      window.makeKeyAndOrderFront(nil)
    } else if let behind, let above = windows[behind], above !== window, above.isVisible {
      window.order(.below, relativeTo: above.windowNumber)
    } else if let key = NSApp.keyWindow, key !== window {
      window.order(.below, relativeTo: key.windowNumber)
    } else {
      window.orderFront(nil)
    }
    observeFrame(window)
    reportFrame(window)
  }

  private static let revealTimeout = 0.6
  private var unrevealed: [String: [() -> Void]] = [:]

  private func holdUntilContent(_ window: NSWindow, id: String, root: NSView) {
    guard !window.isVisible, windows.values.contains(where: { $0.isVisible && isBrowserWindow($0) }) else { return }
    window.alphaValue = 0
    unrevealed[id] = []
    var observer: NSObjectProtocol?
    let reveal: () -> Void = { [weak self, weak window] in
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      guard let self, let waiting = self.unrevealed.removeValue(forKey: id) else { return }
      window?.alphaValue = 1
      CATransaction.flush()
      waiting.forEach { $0() }
    }
    observer = NotificationCenter.default.addObserver(forName: Notification.Name("RCTContentDidAppearNotification"), object: root, queue: .main) {
      _ in reveal()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTimeout, execute: reveal)
  }

  private func noteFirstContent(id: String, root: NSView) {
    if let old = firstContentObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(old) }
    firstContentObservers[id] = NotificationCenter.default.addObserver(
      forName: Notification.Name("RCTContentDidAppearNotification"), object: root, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if let observer = self.firstContentObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
      guard self.windows[id] != nil else { return }
      self.contentShown.insert(id)
      guard self.pendingOrder.contains(where: { self.pendingOpens[$0]?.behind == id }) else { return }
      CATransaction.flush()
      self.openPending(behind: id)
    }
  }

  private func openPending(behind: String) {
    let ids = pendingOrder.filter { pendingOpens[$0]?.behind == behind }
    for id in ids {
      guard let o = pendingOpens.removeValue(forKey: id) else { continue }
      pendingOrder.removeAll { $0 == id }
      contentShown.insert(behind)
      open(
        id: id, frame: o.frame, incognito: o.incognito, title: o.title, focus: false, kind: o.kind, profile: o.profile, size: o.size,
        behind: behind, chromeWindow: o.chromeWindow, claim: o.claim)
    }
  }

  func whenRevealed(_ id: String, _ then: @escaping () -> Void) {
    if unrevealed[id] != nil { unrevealed[id]!.append(then) } else { then() }
  }

  private final class TypeAhead {
    weak var window: NSWindow?
    var keys: [NSEvent] = []
    var watches: [NSObjectProtocol] = []
    var keyed = false
    var passing = false
    init(_ window: NSWindow) { self.window = window }
  }
  private var typeAhead: TypeAhead?
  private var typingMonitor: Any?
  private weak var keyOnReveal: NSWindow?

  private func holdTyping(in window: NSWindow) {
    endTypeAhead(send: false)
    typingMonitor = typingMonitor ?? NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self, let held = self.typeAhead, let window = held.window, !held.passing, !held.keyed || event.window === window,
        !held.keys.isEmpty || (event.type == .keyDown && (!held.keyed || !event.modifierFlags.contains(.command)))
      else { return event }
      guard held.keys.count < 256 else {
        self.endTypeAhead(send: false)
        return event
      }
      held.keys.append(event)
      return nil
    }
    let held = TypeAhead(window)
    held.watches.append(window.observe(\.firstResponder) { [weak self, weak held] window, _ in
      guard held?.keyed == true, Self.takesTyping(window.firstResponder) else { return }
      DispatchQueue.main.async { if let held, self?.typeAhead === held { self?.endTypeAhead(send: true) } }
    })
    for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      held.watches.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak held] _ in
        if let held, self?.typeAhead === held { self?.endTypeAhead(send: false) }
      })
    }
    held.watches.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
      [weak self, weak held, weak window] note in
      guard let self, let held, self.typeAhead === held, !held.keyed, note.object as? NSWindow !== window else { return }
      if self.keyOnReveal === window { self.keyOnReveal = nil }
      self.endTypeAhead(send: false)
    })
    typeAhead = held
  }

  private func typeAheadKeyed(_ window: NSWindow) {
    guard let held = typeAhead, held.window === window, !held.keyed else { return }
    held.keyed = true
    held.keys = held.keys.compactMap { Self.retarget($0, to: window) }
    if Self.takesTyping(window.firstResponder) || !window.isKeyWindow { return endTypeAhead(send: window.isKeyWindow) }
    let first = held.keys.firstIndex { $0.type == .keyDown && !$0.modifierFlags.contains(.command) } ?? held.keys.endIndex
    let now = held.keys[..<first]
    held.keys.removeFirst(first)
    held.passing = true
    now.forEach { NSApp.sendEvent($0) }
    held.passing = false
  }

  private static func retarget(_ event: NSEvent, to window: NSWindow) -> NSEvent? {
    if event.windowNumber == window.windowNumber { return event }
    return NSEvent.keyEvent(
      with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
      windowNumber: window.windowNumber, context: nil, characters: event.characters ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode)
  }

  private func endTypeAhead(send: Bool) {
    guard let held = typeAhead else { return }
    typeAhead = nil
    for watch in held.watches {
      if let focused = watch as? NSKeyValueObservation { focused.invalidate() } else { NotificationCenter.default.removeObserver(watch) }
    }
    if send { held.keys.forEach { NSApp.sendEvent($0) } }
  }

  private static func takesTyping(_ responder: NSResponder?) -> Bool {
    responder is NSTextView || responder.map { String(describing: type(of: $0)) == "RenderWidgetHostViewCocoa" } == true
  }

  private func observeFrame(_ window: NSWindow) {
    for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(frameChanged(_:)), name: name, object: window)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(sizeChanged(_:)), name: NSWindow.didResizeNotification, object: window)
  }

  private func observeDelegateNotifications(_ window: NSWindow) {
    for (name, selector) in [
      (NSWindow.didBecomeKeyNotification, #selector(windowDidBecomeKey(_:))),
      (NSWindow.willCloseNotification, #selector(windowWillClose(_:))),
    ] {
      NotificationCenter.default.addObserver(self, selector: selector, name: name, object: window)
    }
  }

  func setProfile(id: String, profile: String, neighbours: [String]) {
    if pendingOpens[id] != nil { pendingOpens[id]!.profile = profile }
    guard let window = windows[id] else { return }
    ChromeWindows.showProfile(profile, in: window)
    if let current = windows[id] { ChromeWindows.prepare(neighbours, for: current) }
  }

  private var lightsCenters: [String: NSPoint] = [:]

  func setTrafficLightsCenter(id: String, center: NSPoint?) {
    lightsCenters[id] = center
    guard let window = windows[id] else { return }
    ChromeWindows.setTrafficLightsCenter(center, in: window)
  }

  private func adopt(from: NSWindow, to: NSWindow) {
    guard let id = id(of: from) else { return }
    NotificationCenter.default.removeObserver(self, name: nil, object: from)
    windows[id] = to
    if lastPlaced === from { lastPlaced = to }
    observeDelegateNotifications(to)
    observeFrame(to)
    reportFrame(to)
  }

  private func openAux(id: String, kind: String, title: String) {
    guard let makeContentView = WindowHost.makeContentView else { return }
    let settings = kind == "settings"
    let size = settings ? NSSize(width: 820, height: 640) : NSSize(width: 640, height: 600)
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    if settings { style.insert(.resizable) }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = title
    window.isReleasedWhenClosed = false
    window.minSize = settings ? NSSize(width: 720, height: 480) : size
    window.tabbingMode = .disallowed
    let controller = NSViewController()
    let root = makeContentView(id)
    controller.view = root
    controller.view.frame = NSRect(origin: .zero, size: size)
    window.contentViewController = controller
    window.setContentSize(size)
    window.delegate = self
    auxKinds[id] = kind
    windows[id] = window
    if !window.setFrameUsingName("Ardia\(kind.capitalized)") { window.center() }
    window.setFrameAutosaveName("Ardia\(kind.capitalized)")
    keepContentSizedAcrossReloads(id: id, root: root)
    relayoutRoot(window)
    window.makeKeyAndOrderFront(nil)
  }

  private func configureSmall(_ window: NSWindow) {
    window.identifier = NSUserInterfaceItemIdentifier("ardia.window.small")
    window.minSize = NSSize(width: 420, height: 300)
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.moveToActiveSpace)
  }

  private func placeSmall(_ window: NSWindow, size: [Double]) {
    let mouse = NSEvent.mouseLocation
    let screen = (NSApp.isActive ? NSApp.keyWindow?.screen : nil)
      ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return window.center() }
    let width = min(max(size.count == 2 ? size[0] : 900, window.minSize.width), visible.width)
    let height = min(max(size.count == 2 ? size[1] : 640, window.minSize.height), visible.height)
    let lift = min(visible.height * 0.05, (visible.height - height) / 2)
    let origin = NSPoint(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2 + lift).rounded())
    window.setFrame(NSRect(origin: origin, size: NSSize(width: width.rounded(), height: height.rounded())), display: false)
  }

  private func place(_ window: NSWindow, frame: [Double]?) {
    if let frame, frame.count == 4 {
      window.setFrame(NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), display: false)
      if let screen = window.screen ?? NSScreen.main {
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
      }
    } else if let source = [NSApp.keyWindow, NSApp.mainWindow, lastPlaced].compactMap({ $0 }).first(where: { isMainWindow($0) })
                ?? windows.values.first(where: { $0.isVisible && isMainWindow($0) }) {
      window.setFrame(NSRect(origin: .zero, size: source.frame.size), display: false)
      let topLeft = NSPoint(x: source.frame.minX, y: source.frame.maxY)
      window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
    } else if let legacy = legacyFrame, windows.isEmpty {
      window.setFrame(from: legacy)
      legacyFrame = nil
    } else {
      window.center()
    }
  }

  func close(id: String) {
    if pendingOpens.removeValue(forKey: id) != nil {
      pendingOrder.removeAll { $0 == id }
      return
    }
    contentShown.remove(id)
    if let observer = firstContentObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
    guard let window = windows[id] else { return }
    if ChromeWindows.root(of: window) != nil {
      NotificationCenter.default.removeObserver(self, name: nil, object: window)
      windows[id] = nil
      window.animationBehavior = .none
      window.orderOut(nil)
      CATransaction.flush()
      if let waiting = unrevealed.removeValue(forKey: id) { waiting.forEach { $0() } }
      stopKeepingContentSized(id)
      lightsCenters[id] = nil
      auxKinds[id] = nil
      smallIds.remove(id)
      ChromeWindows.close(window)
      DispatchQueue.main.async { ChromeWindows.removeRoot(of: window) }
      return
    }
    closingFromJS.insert(id)
    window.close()
  }

  func focus(id: String) {
    if let o = pendingOpens.removeValue(forKey: id) {
      pendingOrder.removeAll { $0 == id }
      return open(id: id, frame: o.frame, incognito: o.incognito, title: o.title, focus: true, kind: o.kind, profile: o.profile, size: o.size)
    }
    windows[id]?.makeKeyAndOrderFront(nil)
  }

  func setTitle(id: String, title: String) {
    if pendingOpens[id] != nil { pendingOpens[id]!.title = title }
    guard let window = windows[id], window.title != title else { return }
    window.title = title
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let id = id(of: sender), auxKinds[id] == nil, !smallIds.contains(id), appEventsObserved, let emit else { return true }
    emit("onWindowEvent", ["type": "closeRequest", "id": id])
    return false
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, let id = id(of: window) else { return }
    if isMainWindow(window) { lastPlaced = window }
    emit?("onWindowEvent", ["type": "focus", "id": id])
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, let id = id(of: window) else { return }
    NotificationCenter.default.removeObserver(self, name: nil, object: window)
    windows[id] = nil
    stopKeepingContentSized(id)
    lightsCenters[id] = nil
    auxKinds[id] = nil
    smallIds.remove(id)
    if closingFromJS.remove(id) == nil {
      emit?("onWindowEvent", ["type": "close", "id": id])
    }
    DispatchQueue.main.async {
      if ChromeWindows.root(of: window) != nil { return ChromeWindows.removeRoot(of: window) }
      window.contentViewController = nil
    }
  }

  @objc private func sizeChanged(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, !window.inLiveResize else { return }
    relayoutRoot(window)
  }

  private var contentSizers: [String: NSObjectProtocol] = [:]

  private func keepContentSized(id: String, root: NSView) {
    if let old = contentSizers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(old) }
    guard let content = root.subviews.first(where: { NSStringFromClass(type(of: $0)).hasSuffix("RootContentView") }) else { return }
    content.postsFrameChangedNotifications = true
    contentSizers[id] = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) {
      [weak root, weak content] _ in
      guard let root, let content, content.superview === root, root.window != nil, !root.bounds.isEmpty,
        content.frame.size != root.bounds.size
      else { return }
      root.needsLayout = true
      content.needsLayout = true
    }
  }

  private var contentReloads: [String: NSObjectProtocol] = [:]

  private func keepContentSizedAcrossReloads(id: String, root: NSView) {
    keepContentSized(id: id, root: root)
    contentReloads[id] = NotificationCenter.default.addObserver(forName: Notification.Name("RCTContentDidAppearNotification"), object: root, queue: .main) {
      [weak self, weak root] _ in
      guard let self, let root, self.contentReloads[id] != nil else { return }
      self.keepContentSized(id: id, root: root)
    }
  }

  private func stopKeepingContentSized(_ id: String) {
    for token in [contentSizers.removeValue(forKey: id), contentReloads.removeValue(forKey: id)] {
      if let token { NotificationCenter.default.removeObserver(token) }
    }
  }

  private func relayoutRoot(_ window: NSWindow) {
    guard let root = ChromeWindows.root(of: window) ?? window.contentView else { return }
    root.needsLayout = true
    for view in root.subviews { view.needsLayout = true }
    root.layoutSubtreeIfNeeded()
  }

  @objc private func frameChanged(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, !window.inLiveResize else { return }
    reportFrame(window)
  }

  private func reportFrame(_ window: NSWindow) {
    guard let id = id(of: window), !window.styleMask.contains(.fullScreen), window.parent == nil else { return }
    let f = window.frame
    emit?("onWindowEvent", ["type": "frame", "id": id, "frame": [f.minX, f.minY, f.width, f.height]])
  }

  var appEventsObserved = false
  var runtime: ObjectIdentifier?

  func runtimeGone(_ gone: ObjectIdentifier) {
    guard runtime == gone else { return }
    runtime = nil
    pendingOpens = [:]
    pendingOrder = []
    emit = nil
    appEventsObserved = false
    replyToTerminate(false)
  }

  func confirmQuit() {
    if MenuState.current.warnBeforeQuitting {
      let alert = NSAlert()
      alert.messageText = "Are you sure you want to quit \(ProcessInfo.processInfo.processName)?"
      alert.informativeText = "Your windows and tabs will be restored the next time you open it."
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Cancel")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask again"
      let response = alert.runModal()
      if alert.suppressionButton?.state == .on { emit?("onAppEvent", ["type": "quitWarningSuppressed"]) }
      guard response == .alertFirstButtonReturn else { return }
    }
    NSApp.terminate(nil)
  }

  func shouldTerminate() -> NSApplication.TerminateReply {
    guard appEventsObserved, let emit else { return .terminateNow }
    guard confirmActiveDownloads() else { return .terminateCancel }
    emit("onAppEvent", ["type": "willQuit"])
    waitForSave()
    return .terminateLater
  }

  private var saveWait: Timer?
  private var lateSaveAlert: NSAlert?
  private let background = ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1"

  private func waitForSave() {
    let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in self?.saveIsLate() }
    RunLoop.main.add(timer, forMode: .common)
    saveWait = timer
  }

  private func saveIsLate() {
    saveWait = nil
    let message = "\(ProcessInfo.processInfo.processName) can't save your session right now."
    if background {
      NSLog("[shell] quit alert: \(message) (Wait / Quit Without Saving): Wait")
      return waitForSave()
    }
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = "If you quit now, your windows and tabs open as they were when it last saved."
    alert.addButton(withTitle: "Wait")
    alert.addButton(withTitle: "Quit Without Saving")
    lateSaveAlert = alert
    let response = alert.runModal()
    lateSaveAlert = nil
    switch response {
    case .alertFirstButtonReturn: waitForSave()
    case .alertSecondButtonReturn:
      DocumentStore.close()
      NSApp.reply(toApplicationShouldTerminate: true)
    default: break
    }
  }

  private func confirmActiveDownloads() -> Bool {
    let count = MenuState.current.downloadsInProgress
    guard count > 0 else { return true }
    let alert = NSAlert()
    alert.messageText = "Are you sure you want to quit \(ProcessInfo.processInfo.processName)?"
    alert.informativeText = count == 1
      ? "You have 1 download in progress. If you quit now, this download will be cancelled."
      : "You have \(count) downloads in progress. If you quit now, these downloads will be cancelled."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  func replyToTerminate(_ ok: Bool) {
    saveWait?.invalidate()
    saveWait = nil
    if lateSaveAlert != nil { NSApp.stopModal(withCode: .abort) }
    if ok {
      if DocumentStore.flush() { ChromeWindows.recordLaunchLayout() } else { ChromeWindows.forgetLaunchPictures() }
    }
    NSApp.reply(toApplicationShouldTerminate: ok)
  }

  func reopen() {
    emit?("onAppEvent", ["type": "reopen"])
  }
}


final class DragPreview {
  static let shared = DragPreview()

  static let card = NSSize(width: 209, height: 110)
  private static let pillMs = 0.03
  private static let morph = 0.06
  private static let grow = 0.2
  private static let fadeOut = 0.1

  private final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  private var panel: Panel?
  private let rim = CALayer()
  private let picture = CALayer()
  private var windowAspect: CGFloat = 0
  private weak var source: NSWindow?
  private var sourceClosing: NSObjectProtocol?
  private var windowImage: CGImage?
  private var pageImage: (image: CGImage, frame: NSRect)?
  private var placeholder = false
  private var cardImage: CGImage?
  private var pillImage: CGImage?
  private var pillSize = NSSize(width: 173, height: 32)
  private var grab = NSPoint(x: 86, y: 16)
  private var shape = "hidden" { didSet { if shape != oldValue { shapes.append(shape) } } }
  private var shapes: [String] = []
  private var wanted = "hidden"
  private var lastPoint = NSPoint.zero
  private var shownAt = 0.0
  private var generation = 0
  private let background = ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1"
  private var animation: Timer?
  private var desired = NSRect.zero

  func begin(windowId: String, chip: NSRect, grab: NSPoint) {
    cancel()
    shapes = []
    guard let window = WindowManager.shared.windows[windowId] else { return }
    source = window
    sourceClosing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
      [weak self] _ in self?.cancel()
    }
    pillSize = chip.size
    self.grab = NSPoint(x: grab.x - chip.minX, y: grab.y - chip.minY)
    windowImage = Self.snapshot(window, scale: 0.5)
    pillImage = Self.snapshot(window, scale: window.backingScaleFactor, of: chip)
    composeCard()
  }

  func setPage(_ data: Data, frame: NSRect) {
    guard source != nil, let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    pageImage = (image, frame)
    placeholder = false
    composeCard()
    if shape == "card" { show(cardImage) }
  }

  func setPlaceholder(title: String, favicon: String?) {
    guard let window = source, pageImage == nil else { return }
    let size = window.frame.size
    let top: CGFloat = 42
    let page = NSRect(x: 0, y: top, width: size.width, height: max(1, size.height - top))
    let icon: NSImage? = favicon.flatMap { spec -> NSImage? in
      guard let url = URL(string: spec) else { return nil }
      if url.isFileURL { return NSImage(contentsOf: url) }
      if url.scheme == "data", let data = try? Data(contentsOf: url) { return NSImage(data: data) }
      return nil
    } ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    let image = NSImage(size: page.size, flipped: false) { rect in
      let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
      rect.fill()
      let iconSide: CGFloat = 64
      let ink = dark ? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0, alpha: 0.6)
      let label = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .medium),
        .foregroundColor: ink,
      ])
      let textSize = label.size()
      let textWidth = min(textSize.width, rect.width - 80)
      let icon = icon?.isTemplate == true ? icon?.withSymbolConfiguration(.init(paletteColors: [ink])) ?? icon : icon
      icon?.draw(in: NSRect(x: rect.midX - iconSide / 2, y: rect.midY + 12, width: iconSide, height: iconSide))
      label.draw(with: NSRect(x: rect.midX - textWidth / 2, y: rect.midY - 12 - textSize.height, width: textWidth, height: textSize.height),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
      return true
    }
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    pageImage = (cg, page)
    placeholder = true
    composeCard()
    if shape == "card" { show(cardImage) }
  }

  func update(shape next: String, at local: NSPoint) {
    guard let source else { return }
    let point = NSPoint(x: source.frame.minX + local.x, y: source.frame.maxY - local.y)
    wanted = next
    lastPoint = point
    if next == "hidden" {
      hide()
      return
    }
    let panel = self.panel ?? makePanel()
    if shape == "hidden" {
      shownAt = ProcessInfo.processInfo.systemUptime
      shape = "pill"
      animation?.invalidate()
      animation = nil
      panel.alphaValue = 1
      place(panel, shape: "pill", at: point, animated: false)
      if background { panel.order(.above, relativeTo: source.windowNumber) } else { panel.orderFrontRegardless() }
      guard next == "card" else { return }
      let gen = generation
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.pillMs) { [weak self] in
        guard let self, self.generation == gen, self.shape == "pill", self.wanted == "card" else { return }
        self.shape = "card"
        self.place(panel, shape: "card", at: self.lastPoint, animated: true)
      }
    } else if shape != next, !(next == "card" && ProcessInfo.processInfo.systemUptime - shownAt < Self.pillMs) {
      shape = next
      place(panel, shape: next, at: point, animated: true)
    } else {
      place(panel, shape: shape, at: point, animated: false)
    }
  }

  func end(windowId: String?, fallback: NSRect?) {
    let panel = self.panel
    let showing = shape != "hidden"
    let whole = windowId != nil ? composeWindow() : nil
    release()
    guard let panel, showing else {
      panel?.orderOut(nil)
      return
    }
    let gen = generation
    let fade: () -> Void = { [weak self] in
      guard let self, self.generation == gen else { return }
      self.animate(panel, to: panel.frame, alpha: 0, duration: Self.fadeOut) { panel.orderOut(nil) }
    }
    guard let windowId, let fallback, fallback.width > 0 else { return fade() }
    if let whole { show(whole.image, windowAspect: whole.aspect) }
    var tries = 0
    func grow() {
      guard generation == gen else { return }
      guard let window = WindowManager.shared.windows[windowId] else {
        tries += 1
        if tries > 20 { return animate(panel, to: fallback, alpha: 1, duration: Self.grow, then: fade) }
        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { grow() }
      }
      if background { panel.order(.above, relativeTo: window.windowNumber) }
      animate(panel, to: window.frame, alpha: 1, duration: Self.grow) {
        WindowManager.shared.whenRevealed(windowId, fade)
      }
    }
    grow()
  }

  func cancel() {
    animation?.invalidate()
    animation = nil
    panel?.orderOut(nil)
    release()
  }

  private func release() {
    generation += 1
    shape = "hidden"
    wanted = "hidden"
    windowAspect = 0
    if let sourceClosing { NotificationCenter.default.removeObserver(sourceClosing) }
    sourceClosing = nil
    source = nil
    windowImage = nil
    pageImage = nil
    placeholder = false
    cardImage = nil
    pillImage = nil
  }

  private func hide() {
    animation?.invalidate()
    animation = nil
    guard shape != "hidden" else { return }
    shape = "hidden"
    panel?.orderOut(nil)
  }

  func debugWrite(dir: String) -> Bool {
    var ok = false
    for (name, image) in [("card", cardImage), ("pill", pillImage)] {
      guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
      ok = (try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("drag-\(name).png"))) != nil || ok
    }
    return ok
  }

  var debugState: [String: Any] {
    let frame = panel?.frame ?? .zero
    return [
      "shape": shape, "shapes": shapes, "visible": panel?.isVisible ?? false, "alpha": panel?.alphaValue ?? 0,
      "frame": [frame.minX, frame.minY, frame.width, frame.height], "page": pageImage != nil, "placeholder": placeholder,
      "key": panel?.isKeyWindow ?? false, "ignoresMouse": panel?.ignoresMouseEvents ?? false,
      "level": panel?.level.rawValue ?? 0, "activeApp": NSRunningApplication.current.isActive,
    ]
  }

  private func animate(_ panel: NSPanel, to frame: NSRect, alpha: CGFloat, duration: Double, then done: (() -> Void)? = nil) {
    animation?.invalidate()
    desired = frame
    let from = panel.frame, fromAlpha = panel.alphaValue
    let start = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / max(duration, 0.001))
      let target = self?.desired ?? frame
      let e = 1 - pow(1 - t, 3)
      let mix = { (a: CGFloat, b: CGFloat) in a + (b - a) * e }
      panel.setFrame(NSRect(x: mix(from.minX, target.minX), y: mix(from.minY, target.minY), width: mix(from.width, target.width),
        height: mix(from.height, target.height)), display: true)
      self?.layoutPicture()
      panel.alphaValue = mix(fromAlpha, alpha)
      guard t >= 1 else { return }
      timer.invalidate()
      if self?.animation === timer { self?.animation = nil }
      done?()
    }
    RunLoop.main.add(timer, forMode: .common)
    animation = timer
  }

  private func makePanel() -> Panel {
    let panel = Panel(contentRect: NSRect(origin: .zero, size: Self.card), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isFloatingPanel = !background
    panel.level = background ? .normal : .floating
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
    let view = NSView(frame: panel.contentLayoutRect)
    view.wantsLayer = true
    view.autoresizingMask = [.width, .height]
    rim.frame = view.bounds
    rim.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    rim.masksToBounds = true
    rim.borderWidth = 0.5
    picture.frame = rim.bounds
    picture.contentsGravity = .resizeAspectFill
    rim.addSublayer(picture)
    view.layer?.addSublayer(rim)
    panel.contentView = view
    self.panel = panel
    return panel
  }

  private func place(_ panel: NSPanel, shape: String, at point: NSPoint, animated: Bool) {
    let pill = shape == "pill"
    let size = pill ? pillSize : Self.card
    let offset = pill ? grab : NSPoint(x: size.width / 2, y: size.height / 2)
    let frame = NSRect(x: (point.x - offset.x).rounded(), y: (point.y - size.height + offset.y).rounded(), width: size.width, height: size.height)
    show(pill ? pillImage : cardImage, fit: pill)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rim.cornerRadius = pill ? 10 : 4
    rim.borderColor = NSColor(white: 1, alpha: pill ? 0.15 : 0.3).cgColor
    CATransaction.commit()
    if animated, panel.frame.size != frame.size {
      animate(panel, to: frame, alpha: 1, duration: Self.morph)
    } else if animation == nil {
      panel.setFrame(frame, display: false)
    } else {
      desired = frame
    }
    layoutPicture()
  }

  private func show(_ image: CGImage?, windowAspect: CGFloat = 0, fit: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.windowAspect = windowAspect
    picture.contents = image
    picture.contentsGravity = windowAspect > 0 ? .resize : fit ? .resizeAspect : .resizeAspectFill
    CATransaction.commit()
    layoutPicture()
  }

  private func layoutPicture() {
    guard let bounds = panel?.contentView?.bounds else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rim.frame = bounds
    if windowAspect > 0 {
      let height = bounds.width * windowAspect
      picture.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    } else {
      picture.frame = bounds
    }
    CATransaction.commit()
  }

  private func composeWindow() -> (image: CGImage, aspect: CGFloat)? {
    guard let window = source, let base = windowImage else { return nil }
    let size = window.frame.size
    guard size.width > 0, size.height > 0 else { return nil }
    let width = base.width, height = base.height
    let scale = CGFloat(width) / size.width
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
    if let page = pageImage {
      let r = page.frame
      ctx.draw(page.image, in: CGRect(x: r.minX * scale, y: CGFloat(height) - r.maxY * scale, width: r.width * scale, height: r.height * scale))
    }
    guard let image = ctx.makeImage() else { return nil }
    return (image, size.height / size.width)
  }

  private func composeCard() {
    guard let window = source, let base = windowImage else { return }
    let size = window.frame.size
    let scale = 2.0
    let width = Int(Self.card.width * scale), height = Int(Self.card.height * scale)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let fit = max(Self.card.width / size.width, Self.card.height / size.height) * scale
    let drawn = CGRect(x: 0, y: CGFloat(height) - size.height * fit, width: size.width * fit, height: size.height * fit)
    ctx.interpolationQuality = .high
    ctx.draw(base, in: drawn)
    if let page = pageImage {
      let r = page.frame
      ctx.draw(page.image, in: CGRect(x: r.minX * fit, y: drawn.maxY - r.maxY * fit, width: r.width * fit, height: r.height * fit))
    }
    cardImage = ctx.makeImage()
  }

  private static func snapshot(_ window: NSWindow, scale: CGFloat, of rect: NSRect? = nil) -> CGImage? {
    guard let view = window.contentView, let layer = view.layer else { return nil }
    let size = view.bounds.size
    let part = rect ?? NSRect(origin: .zero, size: size)
    guard part.width > 0, part.height > 0,
      let ctx = CGContext(data: nil, width: Int(part.width * scale), height: Int(part.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor((window.backgroundColor ?? .windowBackgroundColor).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: part.width * scale, height: part.height * scale))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -part.minX, y: part.maxY - size.height)
    if view.isFlipped || layer.isGeometryFlipped {
      ctx.translateBy(x: 0, y: size.height)
      ctx.scaleBy(x: 1, y: -1)
    }
    layer.render(in: ctx)
    return ctx.makeImage()
  }
}
