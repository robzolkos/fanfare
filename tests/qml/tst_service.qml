import QtQuick
import QtTest
import Quickshell.Io
import "../.."

// The service against a fake CLI: each test finishes the processes the
// service starts with the output the real CLI would give.
TestCase {
  name: "Service"

  property var service: null
  readonly property string statePath: "/state/fanfare/state.json"

  Component {
    id: serviceComponent
    Service {}
  }

  function rawBoost(id, at, opts) {
    opts = opts || {}
    var recordingId = opts.recordingId || 100
    return {
      id: id, content: opts.content || "👍", created_at: at,
      booster: { id: 1, name: opts.name || "Ada Lovelace", avatar_url: "", personable_type: opts.type || "User" },
      recording: {
        id: recordingId, type: "Comment", title: "Re: Fix the thing",
        url: "https://3.basecampapi.com/1/buckets/2/comments/" + recordingId + ".json",
        app_url: "https://app.basecamp.com/1/buckets/2/card_tables/cards/3#__recording_" + recordingId,
        bucket: { name: "On Call" }, parent: { id: 9, title: "Fix the thing" }
      }
    }
  }

  function page(items) { return JSON.stringify({ ok: true, data: items }) }

  function probeOutput(defaultId, accounts) {
    return JSON.stringify({ ok: true, data: { account_id: defaultId, authenticated: true } })
      + "\n--accounts--\n" + JSON.stringify({ ok: true, data: accounts })
  }

  function running(test) {
    var list = ProcessRegistry.processes
    for (var i = 0; i < list.length; i++) if (list[i].running && test(list[i].command || [])) return list[i]
    return null
  }

  function waitFor(test, what) {
    var found = null
    tryVerify(function() { found = running(test); return found !== null }, 2000, "waiting for " + what)
    return found
  }

  function probe() { return waitFor(function(c) { return c[0] === "bash" && String(c[2]).indexOf("--accounts--") !== -1 }, "the accounts probe") }

  function pageFor(account, n) {
    return waitFor(function(c) {
      return c[5] === "/my/boosts.json?page=" + n && c[c.length - 1] === String(account)
    }, "page " + n + " of account " + account)
  }

  function toasts() {
    return ProcessRegistry.processes.filter(function(p) { return (p.command || [])[0] === "omarchy-notification-send" })
  }

  function start(settings, savedState) {
    ProcessRegistry.reset()
    FileStore.reset()
    if (savedState) FileStore.write(statePath, savedState)
    service = serviceComponent.createObject(this, { settings: settings || {} })
    verify(service !== null)
    waitFor(function(c) { return c[0] === "mkdir" }, "the state directory").complete(0, "", "")
    tryCompare(service, "stateLoaded", true)
  }

  // A first load of one account, two boosts.
  function loadOneAccount() {
    probe().complete(0, probeOutput("7", [{ id: 7, name: "Seven" }]), "")
    pageFor("7", 1).complete(0, page([rawBoost(2, "2026-10-08T11:00:00Z"), rawBoost(1, "2026-10-08T10:00:00Z")]), "")
    pageFor("7", 2).complete(0, page([]), "")
    tryCompare(service, "baselineLoaded", true)
  }

  function cleanup() {
    if (service) service.destroy()
    service = null
  }

  function test_first_load_is_quiet_and_saves_marks() {
    start()
    loadOneAccount()
    compare(service.boosts.length, 2)
    compare(service.unseenCount, 0)
    compare(toasts().length, 0)
    tryVerify(function() { return FileStore.read(statePath) !== undefined }, 2000)
    var saved = JSON.parse(FileStore.read(statePath))
    compare(saved.accounts["default|7"].toasted, "2026-10-08T11:00:00Z")
    compare(saved.accounts["default|7"].seen, "2026-10-08T11:00:00Z")
  }

  function test_a_new_boost_toasts_and_lights_the_icon() {
    start()
    loadOneAccount()
    service.refresh(false)
    pageFor("7", 1).complete(0, page([rawBoost(3, "2026-10-08T12:00:00Z", { content: "🎉", name: "Grace Hopper" }), rawBoost(2, "2026-10-08T11:00:00Z")]), "")
    tryCompare(service, "refreshing", false)
    compare(service.boosts.length, 3)
    compare(service.unseenCount, 1)
    compare(toasts().length, 1)
    verify(toasts()[0].command.indexOf("Grace Hopper boosted 🎉") !== -1)
    service.markSeen()
    compare(service.unseenCount, 0)
  }

  function sounds() {
    return ProcessRegistry.processes.filter(function(p) { var c = p.command || []; return c[0] === "bash" && c[3] === "fanfare-sound" })
  }

  function test_the_fanfare_plays_for_new_boosts_only_when_on() {
    start({ sound: true })
    loadOneAccount()
    compare(sounds().length, 0)  // a first load is quiet
    service.refresh(false)
    pageFor("7", 1).complete(0, page([rawBoost(3, "2026-10-08T12:00:00Z"), rawBoost(2, "2026-10-08T11:00:00Z")]), "")
    tryCompare(service, "refreshing", false)
    compare(sounds().length, 1)
    verify(sounds()[0].command[sounds()[0].command.length - 1].indexOf("sounds/fanfare.ogg") !== -1)
  }

  function test_no_fanfare_by_default() {
    start()
    loadOneAccount()
    service.refresh(false)
    pageFor("7", 1).complete(0, page([rawBoost(3, "2026-10-08T12:00:00Z"), rawBoost(2, "2026-10-08T11:00:00Z")]), "")
    tryCompare(service, "refreshing", false)
    compare(toasts().length, 1)
    compare(sounds().length, 0)
  }

  function test_a_boost_that_arrived_while_stopped_toasts_on_start() {
    start({}, JSON.stringify({ version: 1, accounts: { "default|7": { toasted: "2026-10-08T11:00:00Z", seen: "2026-10-08T11:00:00Z" } } }))
    probe().complete(0, probeOutput("7", [{ id: 7, name: "Seven" }]), "")
    pageFor("7", 1).complete(0, page([rawBoost(3, "2026-10-08T12:00:00Z", { name: "Grace Hopper" }), rawBoost(2, "2026-10-08T11:00:00Z")]), "")
    pageFor("7", 2).complete(0, page([]), "")
    tryCompare(service, "baselineLoaded", true)
    compare(toasts().length, 1)
    compare(service.unseenCount, 1)
  }

  function test_a_newly_ticked_account_loads_quietly() {
    start({ accounts: ["7"] })
    probe().complete(0, probeOutput("7", [{ id: 7, name: "Seven" }, { id: 8, name: "Eight" }]), "")
    pageFor("7", 1).complete(0, page([rawBoost(1, "2026-10-08T10:00:00Z")]), "")
    pageFor("7", 2).complete(0, page([]), "")
    tryCompare(service, "baselineLoaded", true)

    service.settings = { accounts: ["7", "8"] }
    pageFor("7", 1).complete(0, page([rawBoost(1, "2026-10-08T10:00:00Z")]), "")
    pageFor("8", 1).complete(0, page([rawBoost(5, "2026-10-08T12:00:00Z", { recordingId: 200 })]), "")
    pageFor("8", 2).complete(0, page([]), "")
    tryCompare(service, "refreshing", false)
    compare(service.boosts.length, 2)
    compare(toasts().length, 0)
    compare(service.unseenCount, 0)
  }

  function test_one_failing_account_keeps_the_others() {
    start({ accounts: ["7", "8"] })
    probe().complete(0, probeOutput("7", [{ id: 7, name: "Seven" }, { id: 8, name: "Eight" }]), "")
    pageFor("7", 1).complete(0, page([rawBoost(1, "2026-10-08T10:00:00Z")]), "")
    pageFor("7", 2).complete(0, page([]), "")
    pageFor("8", 1).complete(1, JSON.stringify({ ok: false, error: "Resource not found", code: "not_found" }), "")
    tryCompare(service, "refreshing", false)
    compare(service.boosts.length, 1)
    verify(service.lastError.indexOf("Eight") === 0, service.lastError)
    verify(!service.signedOut)
  }

  function test_signed_out_and_missing_cli() {
    start()
    probe().complete(0, "{}\n--accounts--\n" + JSON.stringify({ ok: false, error: "Not authenticated", code: "auth_required" }), "")
    tryCompare(service, "refreshing", false)
    verify(service.signedOut)
    verify(!service.cliMissing)

    service.refresh(true)
    probe().complete(127, "", "")
    tryCompare(service, "refreshing", false)
    verify(service.cliMissing)
  }

  function test_toasts_use_the_angled_trumpet_once_drawn() {
    start()
    var icon = waitFor(function(c) { return c[3] === "fanfare-icon" }, "the toast icon")
    verify(icon.command[2].indexOf("-rotate -45") !== -1)
    compare(icon.command[6], "#cdd6f4")
    icon.complete(0, "", "")
    loadOneAccount()
    service.refresh(false)
    pageFor("7", 1).complete(0, page([rawBoost(3, "2026-10-08T12:00:00Z"), rawBoost(2, "2026-10-08T11:00:00Z")]), "")
    tryCompare(service, "refreshing", false)
    var cmd = toasts()[0].command
    compare(cmd[cmd.indexOf("--image") + 1], "/state/fanfare/trumpet-cdd6f4.png")
  }

  function test_a_run_under_an_old_cli_home_is_dropped() {
    start()
    var oldProbe = probe()
    service.settings = { cliConfigHome: "/dev/home" }
    oldProbe.complete(0, probeOutput("7", [{ id: 7, name: "Seven" }]), "")
    // The stale answer is ignored, and a probe under the new home follows.
    var fresh = waitFor(function(c) { return c[0] === "bash" && String(c[2]).indexOf("--accounts--") !== -1 }, "a probe under the new home")
    compare(fresh.environment.XDG_CONFIG_HOME, "/dev/home")
    compare(service.accounts.length, 0)
  }
}
