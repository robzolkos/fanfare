import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// One instance per shell: every bar (one per monitor) reads this service, so
// one poll runs no matter how many monitors there are.
Item {
  id: root

  property var settings: ({})
  property bool refreshing: false
  property var boosts: []
  property date lastUpdated: new Date(0)
  property string lastError: ""
  property bool cliMissing: false
  property bool signedOut: false

  // Boosts from agents and other bots stay off the wall until Basecamp itself
  // offers that filter. The model can still include them: flip this to bring
  // them back.
  readonly property bool showAgentBoosts: false
  readonly property bool notify: setting("notify", true) !== false
  readonly property bool sound: setting("sound", false) === true
  readonly property string soundPath: Qt.resolvedUrl("sounds/fanfare.ogg")
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 60, 3600)

  // Hidden, for development: run the CLI against another config home (say,
  // one whose default profile points at a local development server), leaving
  // the user's own CLI login alone. Only an absolute path counts.
  readonly property string cliConfigHome: /^\/[^\0]*$/.test(String(setting("cliConfigHome", ""))) ? String(setting("cliConfigHome", "")) : ""
  readonly property var cliEnvironment: cliConfigHome !== "" ? ({ XDG_CONFIG_HOME: cliConfigHome }) : ({})
  // Hidden, for development: { from, to } prefixes to fix links from a dev
  // server that points them at the wrong host.
  readonly property var linkRewrite: {
    var value = setting("linkRewrite", null)
    return value && value.from && value.to ? { from: String(value.from), to: String(value.to) } : null
  }

  // Every account this login reaches, the CLI's default, and the ones being
  // watched: those picked in settings, else the default.
  property var accounts: []
  property string defaultAccountId: ""
  property double accountsCheckedMs: 0
  readonly property int accountsRecheckMs: 60 * 60 * 1000
  readonly property var watched: Model.watchedAccounts(setting("accounts", null), accounts, defaultAccountId)
  readonly property var watchedIds: watched.map(function(account) { return account.id })
  readonly property string watchedKey: watchedIds.join(",")

  // The boosts the panel shows, newest first.
  readonly property var feed: Model.visibleBoosts(boosts, showAgentBoosts)
  readonly property int visibleCount: feed.length

  // Two marks per account, saved across restarts: boosts newer than
  // `toastedThrough` toast on the next refresh (so one that lands while the
  // shell is down still announces itself), and boosts newer than
  // `seenThrough` light the bar icon until the panel is opened. An account's
  // first load sets both, so it starts out quiet.
  property var toastedThrough: ({})
  property var seenThrough: ({})
  readonly property int unseenCount: baselineLoaded ? Model.countSince(boosts, showAgentBoosts, seenThrough) : 0

  // Saved state: timestamps only, never boost content, keyed by CLI home and
  // account so a development login never touches the real one's marks.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/fanfare"
  readonly property string statePath: stateDir + "/state.json"
  property var savedState: ({})
  property bool stateLoaded: false

  // The toast shows the trumpet at the bar's angle, drawn into a PNG in the
  // notification text colour (a toast glyph can't be rotated). Redrawn when
  // the theme changes that colour; until it exists, toasts use the glyph.
  readonly property string toastIconColor: String(Color.notifications.text)
  property string toastIconPath: ""

  property bool baselineLoaded: false
  property double lastFullMs: 0
  readonly property int fullReloadMs: 60 * 60 * 1000

  // Accounts loaded this session: anything else walks its full history.
  property var _loadedAccounts: ({})
  // The accounts watched as of the last refresh, to spot newly ticked ones.
  property var _lastWatched: []
  property bool _forceFull: false
  property bool _fullReload: false
  property bool _pendingRefresh: false
  property bool _pendingForce: false
  // The CLI home a refresh started under; results from a run that began
  // under another one are stale and dropped.
  property string _runHome: ""
  property var _queue: []
  property var _account: null
  property bool _accountFull: false
  property var _fetchedAccounts: ({})
  property var _failedAccounts: ({})
  property var _partialErrors: []
  property int _page: 1
  property var _known: ({})
  property var _fetched: []
  property string _pageOutput: ""
  property string _pageError: ""
  property string _probeOutput: ""

  // Text of your boosted comments and answers, by recording id, fetched one at
  // a time after each refresh and kept for the life of the shell. The panel
  // reads it per entry, so an arriving excerpt doesn't rebuild the list.
  property var excerpts: ({})
  property var excerptFailed: ({})
  property var _excerptTarget: null
  property int _excerptBudget: 0
  property string _excerptOutput: ""

  property int _toastId: 0
  property double _toastAtMs: 0
  readonly property int toastReplaceWindowMs: 5 * 60 * 1000

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function copy(map) {
    var out = {}
    for (var key in map) out[key] = map[key]
    return out
  }

  function refresh(forceFull) {
    if (refreshing || !stateLoaded) {
      _pendingRefresh = true
      _pendingForce = _pendingForce || forceFull === true
      return
    }
    refreshing = true
    lastError = ""
    _runHome = cliConfigHome
    _forceFull = forceFull === true
    // The account list changes rarely: read it on the first refresh, when
    // forced, and hourly.
    if (accounts.length === 0 || _forceFull || Date.now() - accountsCheckedMs > accountsRecheckMs) {
      _probeOutput = ""
      probeProcess.command = Model.accountsProbeCommand()
      probeProcess.environment = cliEnvironment
      probeProcess.running = true
    } else {
      startFetch()
    }
  }

  function refreshIfStale() {
    var updatedAt = lastUpdated instanceof Date ? lastUpdated.getTime() : 0
    if (updatedAt <= 0 || Date.now() - updatedAt >= 60 * 1000) refresh(false)
  }

  function markSeen() {
    var newest = Model.newestByAccount(boosts)
    var marks = copy(seenThrough)
    for (var account in newest) if (!marks[account] || newest[account] > marks[account]) marks[account] = newest[account]
    seenThrough = marks
    saveState()
  }

  function loadState(text) {
    if (stateLoaded) return
    savedState = Model.parseState(text)
    applySavedMarks()
    stateLoaded = true
    runPendingRefresh()
  }

  function applySavedMarks() {
    var marks = Model.marksFor(savedState, cliConfigHome)
    toastedThrough = marks.toasted
    seenThrough = marks.seen
  }

  function saveState() {
    if (!stateLoaded) return
    savedState = Model.withMarks(savedState, cliConfigHome, toastedThrough, seenThrough)
    stateSaveTimer.restart()
  }

  // A run that began under another CLI home answers for the wrong server.
  function staleRun() {
    if (_runHome === cliConfigHome) return false
    refreshing = false
    _pendingRefresh = false
    _pendingForce = false
    Qt.callLater(function() { root.refresh(true) })
    return true
  }

  function probeFinished(exitCode, stdout) {
    if (staleRun()) return
    if (exitCode === 127) {
      cliMissing = true
      fail("The Basecamp CLI isn't installed")
      return
    }
    cliMissing = false
    var probe = Model.parseAccountsProbe(stdout)
    if (!probe.ok) {
      signedOut = probe.code === "auth_required"
      fail(signedOut ? "Signed out of the Basecamp CLI" : probe.error)
      return
    }
    signedOut = false
    accounts = probe.accounts
    defaultAccountId = probe.defaultId
    accountsCheckedMs = Date.now()
    startFetch()
  }

  // One account after another, each walking its pages; then merge.
  function startFetch() {
    var list = watched
    if (list.length === 0) {
      fail("No Basecamp accounts on this login")
      return
    }
    _fullReload = _forceFull || boosts.length === 0 || Date.now() - lastFullMs > fullReloadMs
    _known = Model.idSet(boosts)
    _fetched = []
    _fetchedAccounts = {}
    _failedAccounts = {}
    _partialErrors = []
    _queue = list.slice()
    nextAccount()
  }

  function nextAccount() {
    if (_queue.length === 0) {
      finishRefresh()
      return
    }
    var queue = _queue.slice()
    _account = queue.shift()
    _queue = queue
    // An account not yet loaded this session walks its whole history.
    _accountFull = _fullReload || !_loadedAccounts[_account.id]
    fetchPage(1)
  }

  function fetchPage(page) {
    _page = page
    _pageOutput = ""
    _pageError = ""
    pageProcess.command = Model.boostsPageCommand(page, _account.id)
    pageProcess.environment = cliEnvironment
    pageProcess.running = true
  }

  function pageFinished(exitCode, stdout, stderr) {
    if (staleRun()) return
    if (exitCode === 127 && stdout.trim() === "") {
      cliMissing = true
      fail("The Basecamp CLI isn't installed")
      return
    }
    cliMissing = false
    var page = exitCode === 124
      ? { ok: false, error: "didn't answer within 30 seconds", code: "" }
      : Model.parsePage(stdout, _account)
    if (!page.ok) {
      if (page.code === "auth_required") {
        // Shared credentials: every other account would fail the same way.
        signedOut = true
        fail("Signed out of the Basecamp CLI")
        return
      }
      // One account failing doesn't empty the wall: keep what it had and say
      // which account it was.
      var failed = copy(_failedAccounts)
      failed[_account.id] = true
      _failedAccounts = failed
      _partialErrors = _partialErrors.concat([_account.name + ": " + (page.error || Model.cleanText(stderr, 120))])
      nextAccount()
      return
    }
    signedOut = false
    _fetched = _fetched.concat(page.boosts)
    if (Model.wantsNextPage(page.boosts, _known, _page, _accountFull)) {
      fetchPage(_page + 1)
    } else {
      var done = copy(_fetchedAccounts)
      done[_account.id] = true
      _fetchedAccounts = done
      nextAccount()
    }
  }

  function fail(message) {
    lastError = message || "Could not load boosts"
    refreshing = false
    runPendingRefresh()
  }

  function runPendingRefresh() {
    if (!_pendingRefresh) return
    var force = _pendingForce
    _pendingRefresh = false
    _pendingForce = false
    Qt.callLater(function() { root.refresh(force) })
  }

  function finishRefresh() {
    // New since each account's toasted mark; an account with no mark is on
    // its first load and stays quiet.
    var fresh = Model.boostsAfter(_fetched, toastedThrough, showAgentBoosts)

    // A full reload replaces what we hold, except for accounts that failed
    // this time, which keep their last good boosts.
    var keep = boosts
    if (_fullReload) {
      keep = []
      for (var b = 0; b < boosts.length; b++) if (_failedAccounts[boosts[b].accountId]) keep.push(boosts[b])
    }
    boosts = Model.mergeBoosts(keep, _fetched, false, watchedIds)
    if (_fullReload) lastFullMs = Date.now()

    // Move each fetched account's toasted mark up to its newest boost; an
    // account's first load also counts as seen.
    var newest = Model.newestByAccount(_fetched)
    var toasted = copy(toastedThrough)
    var seen = copy(seenThrough)
    var loaded = copy(_loadedAccounts)
    for (var account in _fetchedAccounts) {
      var latest = newest[account] || ""
      if (!toasted[account] || latest > toasted[account]) toasted[account] = latest || toasted[account] || new Date().toISOString()
      if (!seen[account]) seen[account] = toasted[account]
      loaded[account] = true
    }
    toastedThrough = toasted
    seenThrough = seen
    _loadedAccounts = loaded
    _lastWatched = watchedIds.slice()
    baselineLoaded = true
    saveState()

    lastUpdated = new Date()
    lastError = _partialErrors.join(" · ")
    refreshing = false
    if (notify && fresh.length > 0) sendToast(fresh)
    if (sound && fresh.length > 0) playFanfare()
    fetchExcerpts()
    runPendingRefresh()
  }

  // A different CLI home is a different server: start over.
  onCliConfigHomeChanged: {
    accounts = []
    defaultAccountId = ""
    accountsCheckedMs = 0
    boosts = []
    _loadedAccounts = ({})
    _lastWatched = []
    applySavedMarks()
    baselineLoaded = false
    excerpts = ({})
    excerptFailed = ({})
    // A refresh already running against the old home finishes first; this
    // one follows it with the new environment.
    Qt.callLater(function() { root.refresh(true) })
  }

  // Picking accounts takes effect at once: unwatched ones drop off now, and a
  // newly watched one loads on the refresh this starts.
  onWatchedKeyChanged: {
    if (!baselineLoaded) return
    // A newly ticked account starts fresh: its old marks would toast
    // everything it gathered while unwatched.
    var toasted = copy(toastedThrough)
    var seen = copy(seenThrough)
    for (var i = 0; i < watchedIds.length; i++) {
      if (_lastWatched.indexOf(watchedIds[i]) !== -1) continue
      delete toasted[watchedIds[i]]
      delete seen[watchedIds[i]]
    }
    toastedThrough = toasted
    seenThrough = seen
    boosts = Model.mergeBoosts(boosts, [], false, watchedIds)
    refresh(false)
  }

  // Each pass (a refresh, or the bot filter changing what's on screen) may
  // fetch up to excerptFetchLimit excerpts, in screen order.
  function fetchExcerpts() {
    _excerptBudget = Model.excerptFetchLimit
    fetchNextExcerpt()
  }

  function fetchNextExcerpt() {
    if (excerptProcess.running || _excerptBudget <= 0) return
    var targets = Model.excerptTargets(feed, excerpts, excerptFailed, 1)
    if (targets.length === 0) return
    _excerptBudget -= 1
    _excerptTarget = targets[0]
    _excerptOutput = ""
    excerptProcess.command = Model.excerptCommand(_excerptTarget.apiUrl, _excerptTarget.accountId)
    excerptProcess.environment = cliEnvironment
    excerptProcess.running = true
  }

  function excerptFinished(exitCode, stdout) {
    var target = _excerptTarget
    _excerptTarget = null
    if (!target) return
    var parsed = exitCode === 0 ? Model.parseExcerpt(stdout) : { ok: false }
    if (parsed.ok) {
      var next = copy(excerpts)
      next[target.recordingId] = parsed.text
      excerpts = next
    } else {
      // Deleted, trashed, or no longer visible to you: don't ask again.
      var failed = copy(excerptFailed)
      failed[target.recordingId] = true
      excerptFailed = failed
    }
    Qt.callLater(fetchNextExcerpt)
  }

  function sendToast(fresh) {
    var toast = Model.composeToast(fresh)
    if (!toast || toastProcess.running) return
    toast.url = Model.openableUrl(toast.url, linkRewrite)
    var replaceId = Date.now() - _toastAtMs < toastReplaceWindowMs ? _toastId : 0
    toastProcess.command = Model.toastCommand(toast, replaceId, toastIconPath)
    toastProcess.running = true
  }

  function prepareToastIcon() {
    var path = Model.toastIconPath(stateDir, toastIconColor)
    var command = Model.toastIconCommand(Style.font.family, "󱂖", toastIconColor, path)
    if (command.length === 0 || iconProcess.running) return
    iconProcess.target = path
    iconProcess.command = command
    iconProcess.running = true
  }

  onToastIconColorChanged: if (stateLoaded) prepareToastIcon()

  function playFanfare() {
    var command = Model.soundCommand(soundPath)
    if (command.length === 0 || soundProcess.running) return
    soundProcess.command = command
    soundProcess.running = true
  }

  function testToast(count) {
    var visible = feed.slice(0, Math.max(1, count || 1))
    if (visible.length === 0) return "no boosts to toast"
    sendToast(visible)
    return "ok"
  }

  // Load saved marks once the directory exists; a missing or unreadable file
  // is a first run. The first poll waits for this.
  Process {
    id: stateDirProcess
    running: true
    command: ["mkdir", "-p", root.stateDir]
    onExited: {
      stateFile.reload()
      root.prepareToastIcon()
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  Timer {
    id: stateSaveTimer
    interval: 500
    repeat: false
    onTriggered: stateFile.setText(Model.serializeState(root.savedState))
  }

  // Polls on the configured interval, starting immediately.
  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // bash always exits, so a missing CLI can't leave `refreshing` stuck.
  Process {
    id: probeProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: probeStdout
      waitForEnd: true
      onStreamFinished: root._probeOutput = text
    }
    onExited: function(exitCode) {
      root.probeFinished(exitCode, String(probeStdout.text || root._probeOutput || ""))
    }
  }

  Process {
    id: pageProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: pageStdout
      waitForEnd: true
      onStreamFinished: root._pageOutput = text
    }
    stderr: StdioCollector {
      id: pageStderr
      waitForEnd: true
      onStreamFinished: root._pageError = text
    }
    onExited: function(exitCode) {
      root.pageFinished(exitCode,
        String(pageStdout.text || root._pageOutput || ""),
        String(pageStderr.text || root._pageError || ""))
    }
  }

  Process {
    id: excerptProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: excerptStdout
      waitForEnd: true
      onStreamFinished: root._excerptOutput = text
    }
    onExited: function(exitCode) {
      root.excerptFinished(exitCode, String(excerptStdout.text || root._excerptOutput || ""))
    }
  }

  Process {
    id: iconProcess
    property string target: ""
    running: false
    command: []
    onExited: function(exitCode) {
      root.toastIconPath = exitCode === 0 ? target : ""
    }
  }

  Process {
    id: soundProcess
    running: false
    command: []
  }

  // -p prints the daemon's id, which -r replaces on the next toast so a run
  // of refreshes updates one toast instead of stacking them.
  Process {
    id: toastProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: toastStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var id = parseInt(String(toastStdout.text || "").trim(), 10)
      if (exitCode === 0 && isFinite(id) && id > 0) {
        root._toastId = id
        root._toastAtMs = Date.now()
      }
    }
  }
}
