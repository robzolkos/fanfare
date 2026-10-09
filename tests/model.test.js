// node tests/model.test.js — plain assert, no dependencies.
const assert = require("assert")
const Model = require("../Model.js")

function raw(id, at, opts = {}) {
  const recordingId = opts.recordingId || 100
  return {
    id,
    content: opts.content || "👍",
    created_at: at,
    booster: { id: opts.boosterId || 1, name: opts.name || "Ada Lovelace", avatar_url: "https://example.test/a.webp", personable_type: opts.type || "User" },
    recording: {
      id: recordingId,
      type: opts.recType || "Comment",
      title: opts.recTitle || "Re: Fix the thing",
      created_at: opts.recCreatedAt || at,
      url: "https://3.basecampapi.com/1/buckets/2/comments/" + recordingId + ".json",
      app_url: "https://app.basecamp.com/1/buckets/2/card_tables/cards/3#__recording_" + recordingId,
      bucket: { name: opts.project || "On Call" },
      parent: { id: opts.parentId || 9, title: opts.parentTitle || "Fix the thing", app_url: "https://app.basecamp.com/1/buckets/2/card_tables/cards/" + (opts.parentId || 9) }
    }
  }
}

function page(items) { return JSON.stringify({ ok: true, data: items }) }
function boosts(items) { return Model.parsePage(page(items)).boosts }

const tests = {
  "parses a page and normalizes boosts"() {
    const [boost] = boosts([raw(1, "2026-10-08T10:00:00Z")])
    assert.strictEqual(boost.id, "1")
    assert.strictEqual(boost.boosterName, "Ada Lovelace")
    assert.strictEqual(boost.title, "Fix the thing")
    assert.strictEqual(boost.kind, "Comment")
    assert.strictEqual(boost.selfEntry, false)
    assert.strictEqual(boost.bot, false)
  },

  "boosts are tagged with their account and keyed by it"() {
    const [boost] = Model.parsePage(page([raw(1, "2026-10-08T10:00:00Z")]), { id: "42", name: "Acme" }).boosts
    assert.strictEqual(boost.id, "42:1")
    assert.strictEqual(boost.accountId, "42")
    assert.strictEqual(boost.accountName, "Acme")
  },

  "reads the accounts probe: default account and the list"() {
    const out = JSON.stringify({ ok: true, data: { account_id: "7", authenticated: true } }) + "\n--accounts--\n" +
      JSON.stringify({ ok: true, data: [{ id: 7, name: "Seven" }, { id: 8, name: "Eight" }, { name: "no id" }] })
    assert.deepStrictEqual(Model.parseAccountsProbe(out), { ok: true, error: "", code: "", defaultId: "7", accounts: [{ id: "7", name: "Seven" }, { id: "8", name: "Eight" }] })
    assert.strictEqual(Model.parseAccountsProbe("garbage").ok, false)
    const signedOut = "{}\n--accounts--\n" + JSON.stringify({ ok: false, error: "auth required", code: "auth_required" })
    assert.strictEqual(Model.parseAccountsProbe(signedOut).code, "auth_required")
  },

  "watches the picked accounts, else the default, else the first"() {
    const all = [{ id: "7", name: "Seven" }, { id: "8", name: "Eight" }, { id: "9", name: "Nine" }]
    const ids = list => list.map(a => a.id)
    assert.deepStrictEqual(ids(Model.watchedAccounts(undefined, all, "8")), ["8"])
    assert.deepStrictEqual(ids(Model.watchedAccounts(["9", "7"], all, "8")), ["7", "9"])
    assert.deepStrictEqual(ids(Model.watchedAccounts([], all, "8")), ["8"])
    assert.deepStrictEqual(ids(Model.watchedAccounts(["99"], all, "8")), ["8"])
    assert.deepStrictEqual(ids(Model.watchedAccounts(undefined, all, "")), ["7"])
    assert.deepStrictEqual(Model.watchedAccounts(undefined, [], "8"), [])
    // A Qt list from shell start-up is list-shaped but not a JS Array.
    const qtList = { length: 2, 0: "9", 1: "8" }
    assert.deepStrictEqual(ids(Model.watchedAccounts(qtList, all, "7")), ["8", "9"])
    assert.deepStrictEqual(ids(Model.watchedAccounts("8", all, "7")), ["7"])
  },

  "each account keeps its own latest 200, and unwatched accounts drop out"() {
    const many = (account, n) => Array.from({ length: n }, (_, i) => ({ id: account + ":" + i, accountId: account, createdAt: "2026-10-08T10:" + String(Math.floor(i / 60)).padStart(2, "0") + ":" + String(i % 60).padStart(2, "0") + "Z" }))
    const merged = Model.mergeBoosts([], many("7", 250).concat(many("8", 30)), true)
    assert.strictEqual(merged.filter(b => b.accountId === "7").length, Model.boostLimit)
    assert.strictEqual(merged.filter(b => b.accountId === "8").length, 30)
    assert.strictEqual(Model.mergeBoosts(merged, [], false, ["8"]).length, 30)
  },

  "CLI commands name the account, and only a numeric one"() {
    assert.deepStrictEqual(Model.boostsPageCommand(2, "42").slice(-3), ["--json", "--account", "42"])
    assert.ok(!Model.boostsPageCommand(1, "--help").includes("--account"))
    assert.deepStrictEqual(Model.excerptCommand("https://3.basecampapi.com/42/x.json", "42").slice(-2), ["--account", "42"])
    const [boost] = Model.parsePage(page([raw(1, "2026-10-08T10:00:00Z")]), { id: "42", name: "Acme" }).boosts
    assert.strictEqual(Model.excerptTargets([boost], {}, {})[0].accountId, "42")
  },

  "surfaces CLI errors and their code"() {
    const result = Model.parsePage(JSON.stringify({ ok: false, error: "auth required", code: "auth_required" }))
    assert.ok(!result.ok)
    assert.strictEqual(result.code, "auth_required")
    assert.ok(!Model.parsePage("not json").ok)
  },

  "agents are bots, users and clients are people"() {
    assert.ok(Model.isBot("Agent"))
    assert.ok(!Model.isBot("User"))
    assert.ok(!Model.isBot("Client"))
  },

  "describes what was boosted by where it lives"() {
    const subject = rec => { const s = Model.subjectFor(rec); return [s.title, s.kind, s.project, s.self] }
    assert.deepStrictEqual(subject({ id: 5, type: "Comment", title: "Re: Fix", parent: { id: 9, title: "Fix the thing" }, bucket: { name: "On Call" } }), ["Fix the thing", "Comment", "On Call", false])
    assert.deepStrictEqual(subject({ id: 8, type: "Kanban::Card", title: "My card", parent: { id: 1, title: "Done" } }), ["My card", "Card", "", true])
    assert.deepStrictEqual(subject({ id: 2, type: "Message", title: "Release notes", parent: { id: 3, title: "Message Board" } }), ["Release notes", "Message", "", true])
    assert.deepStrictEqual(subject({ id: 4, type: "Chat::Lines::RichText", title: "ship it", parent: { id: 11, title: "Ping" }, bucket: { name: "Ada + Rob" } }), ["Ping with Ada + Rob", "Ping", "", false])
    assert.deepStrictEqual(subject({ id: 6, type: "Question::Answer", title: "Answer", created_at: "2026-10-07T20:00:00Z", parent: { id: 7, title: "What did you do?" } }), ["What did you do? · Oct 7", "Check-in", "", false])
  },

  "context line says where the boosted thing lives"() {
    const [comment] = boosts([raw(1, "2026-10-08T10:00:00Z")])
    assert.strictEqual(Model.contextLine(comment), "On Fix the thing · On Call")
    const [card] = boosts([raw(2, "2026-10-08T10:00:00Z", { recType: "Kanban::Card", recTitle: "My card" })])
    assert.strictEqual(Model.contextLine(card), "Card · On Call")
    const [line] = boosts([raw(3, "2026-10-08T10:00:00Z", { recType: "Chat::Lines::RichText", recTitle: "ship it", parentTitle: "Chat" })])
    assert.strictEqual(Model.contextLine(line), "In Chat · On Call")
    assert.strictEqual(line.excerpt, "ship it")
    assert.strictEqual(Model.contextLine(null), "")
  },

  "feed is every visible boost newest first, with a heading per day"() {
    const feed = Model.visibleBoosts(boosts([
      raw(4, "2026-10-08T15:00:00Z"),
      raw(3, "2026-10-08T14:00:00Z", { type: "Agent" }),
      raw(2, "2026-10-07T15:00:00Z", { recordingId: 101 }),
      raw(1, "2026-10-07T14:00:00Z")
    ]), false)
    const rows = Model.feedRows(feed, Date.parse("2026-10-08T20:00:00"))
    assert.deepStrictEqual(rows.map(r => r.header ? r.label : r.boost.id), ["Boosted today", "4", "Boosted yesterday", "2", "1"])
    assert.deepStrictEqual(rows.filter(r => !r.header).map(r => r.index), [0, 1, 2])
  },

  "mosaic sections are days, newest first, with counts and feed indexes"() {
    const feed = boosts([raw(3, "2026-10-08T15:00:00Z"), raw(2, "2026-10-08T14:00:00Z"), raw(1, "2026-10-06T14:00:00Z")])
    const sections = Model.daySections(feed, Date.parse("2026-10-08T20:00:00"))
    assert.deepStrictEqual(sections.map(s => [s.label, s.count]), [["Today", 2], ["Tuesday", 1]])
    assert.deepStrictEqual(sections[1].items.map(i => i.index), [2])
  },

  "arrow keys move to the item above or below"() {
    const cells = [
      { index: 0, row: 0, col: 0, span: 1 }, { index: 1, row: 0, col: 1, span: 3 },
      { index: 2, row: 1, col: 0, span: 2 }, { index: 3, row: 1, col: 2, span: 1 },
      { index: 4, row: 3, col: 3, span: 1 }
    ]
    assert.strictEqual(Model.gridNeighbor(cells, 1, 0, 1), 3)
    assert.strictEqual(Model.gridNeighbor(cells, 0, 0, 1), 2)
    assert.strictEqual(Model.gridNeighbor(cells, 3, 0, -1), 1)
    assert.strictEqual(Model.gridNeighbor(cells, 3, 0, 1), 4)
    assert.strictEqual(Model.gridNeighbor(cells, 0, 0, -1), 0)
    assert.strictEqual(Model.gridNeighbor(cells, 2, 1, 0), 3)
    assert.strictEqual(Model.gridNeighbor(cells, 4, 1, 0), 4)
  },

  "excerpts are fetched for comments and answers, once each, newest first"() {
    const feed = boosts([
      raw(4, "2026-10-08T15:00:00Z", { recordingId: 100 }),
      raw(3, "2026-10-08T14:00:00Z", { recordingId: 100 }),
      raw(2, "2026-10-08T13:00:00Z", { recType: "Kanban::Card", recordingId: 300 }),
      raw(1, "2026-10-08T12:00:00Z", { recType: "Chat::Lines::RichText", recordingId: 400, recTitle: "hi" }),
      raw(0, "2026-10-08T11:00:00Z", { recordingId: 101 })
    ])
    assert.deepStrictEqual(Model.excerptTargets(feed, {}, {}).map(t => t.recordingId), ["100", "101"])
    assert.deepStrictEqual(Model.excerptTargets(feed, { "100": "x" }, { "101": true }), [])
    assert.deepStrictEqual(Model.excerptTargets(feed, {}, {}, 1).map(t => t.recordingId), ["100"])
  },

  "excerpt targets need a basecampapi json url"() {
    const [boost] = boosts([raw(1, "2026-10-08T10:00:00Z")])
    boost.recordingApiUrl = "--version"
    assert.deepStrictEqual(Model.excerptTargets([boost], {}, {}), [])
  },

  "rich text becomes one plain line with @mentions"() {
    const html = '<p dir="auto"><bc-attachment sgid="x" content-type="application/vnd.basecamp.mention"><figure><img alt="Ada"><figcaption>Ada</figcaption></figure></bc-attachment> can you look &amp; fix?</p><p>Thanks<br>Rob</p>'
    assert.strictEqual(Model.htmlToText(html), "@Ada can you look & fix? Thanks Rob")
    assert.strictEqual(Model.htmlToText('<bc-attachment content-type="image/png"><figure><figcaption>shot.png</figcaption></figure></bc-attachment>'), "📎 shot.png")
    assert.strictEqual(Model.htmlToText("<p>" + "a".repeat(400) + "</p>").length, 180)
    assert.deepStrictEqual(Model.parseExcerpt(JSON.stringify({ content: "<p>hi</p>" })), { ok: true, text: "hi" })
    assert.strictEqual(Model.parseExcerpt("<p>raw</p>").ok, false)
  },

  "hides bot boosts unless asked"() {
    const all = boosts([raw(2, "2026-10-08T11:00:00Z", { type: "Agent" }), raw(1, "2026-10-08T10:00:00Z")])
    assert.deepStrictEqual(Model.visibleBoosts(all, false).map(b => b.id), ["1"])
    assert.deepStrictEqual(Model.visibleBoosts(all, true).map(b => b.id), ["2", "1"])
  },

  "walks pages only while everything is new"() {
    const known = { "5": true }
    const fresh = [{ id: "9" }, { id: "8" }]
    const overlapping = [{ id: "6" }, { id: "5" }]
    assert.ok(Model.wantsNextPage(fresh, known, 1, false))
    assert.ok(!Model.wantsNextPage(overlapping, known, 1, false))
    assert.ok(Model.wantsNextPage(overlapping, known, 1, true))
    assert.ok(!Model.wantsNextPage([], known, 1, true))
    assert.ok(!Model.wantsNextPage(fresh, known, Model.maxPages, true))
  },

  "merges incrementally, replaces on full reload, caps at the API limit"() {
    const a = { id: "1", createdAt: "2026-10-08T10:00:00Z" }
    const b = { id: "2", createdAt: "2026-10-08T11:00:00Z" }
    assert.deepStrictEqual(Model.mergeBoosts([a], [b, a], false).map(x => x.id), ["2", "1"])
    assert.deepStrictEqual(Model.mergeBoosts([a], [b], true).map(x => x.id), ["2"])
    const many = []
    for (let i = 0; i < 250; i++) many.push({ id: String(i), createdAt: "2026-10-08T10:00:" + String(i % 60).padStart(2, "0") + "Z" })
    assert.strictEqual(Model.mergeBoosts([], many, true).length, Model.boostLimit)
  },

  "composes one toast per refresh"() {
    const one = Model.composeToast([{ boosterName: "Ada Lovelace", content: "❤️", title: "Fix the thing", url: "https://x.test/1" }])
    assert.strictEqual(one.headline, "Ada Lovelace boosted ❤️")
    assert.strictEqual(one.description, "Fix the thing")
    const many = Model.composeToast([1, 2, 3, 4, 5].map(i => ({ boosterName: "Person " + i, content: "👍", title: "t", url: "https://x.test/" + i })))
    assert.strictEqual(many.headline, "5 new boosts")
    assert.ok(many.description.endsWith("and 2 more"))
    assert.strictEqual(many.url, "https://x.test/1")
    assert.strictEqual(Model.composeToast([]), null)
    assert.strictEqual(Model.composeToast([{ boosterName: "Ada", content: "🎺", title: "Chat", excerpt: "Deploy is out", url: "https://x.test/1" }]).description, "Deploy is out")
  },

  "toast command opens https links only"() {
    const cmd = Model.toastCommand({ headline: "h", description: "d", url: "https://app.basecamp.com/1" }, 7)
    assert.deepStrictEqual(cmd.slice(-3), ["--exec", "xdg-open", "https://app.basecamp.com/1"])
    assert.ok(cmd.includes("-r"))
    assert.ok(!Model.toastCommand({ headline: "h", url: "file:///etc/passwd" }, 0).includes("--exec"))
  },

  "opens https anywhere, http only on .localhost, after any rewrite"() {
    assert.strictEqual(Model.openableUrl("https://app.basecamp.com/1/buckets/2"), "https://app.basecamp.com/1/buckets/2")
    assert.strictEqual(Model.openableUrl("http://app.localhost:3001/1/x"), "http://app.localhost:3001/1/x")
    assert.strictEqual(Model.openableUrl("http://example.com/x"), "")
    assert.strictEqual(Model.openableUrl("file:///etc/passwd"), "")
    assert.strictEqual(Model.openableUrl("javascript:alert(1)"), "")
    const rewrite = { from: "http://wrong.localhost:4001/", to: "http://right.localhost:3001/" }
    assert.strictEqual(Model.openableUrl("http://wrong.localhost:4001/1/messages/2", rewrite), "http://right.localhost:3001/1/messages/2")
    assert.strictEqual(Model.openableUrl("https://app.basecamp.com/1", rewrite), "https://app.basecamp.com/1")
    // A rewrite can't turn a link into something unsafe.
    assert.strictEqual(Model.openableUrl("http://wrong.localhost:4001/x", { from: "http://wrong.localhost:4001/", to: "file:///" }), "")
    const toast = Model.toastCommand({ headline: "h", url: "http://app.localhost:3001/1/x" }, 0)
    assert.deepStrictEqual(toast.slice(-3), ["--exec", "xdg-open", "http://app.localhost:3001/1/x"])
  },

  "the toast icon is an angled trumpet image, per colour, with the glyph as fallback"() {
    assert.strictEqual(Model.toastIconPath("/state/fanfare", "#CDD6F4"), "/state/fanfare/trumpet-cdd6f4.png")
    assert.strictEqual(Model.toastIconPath("/state/fanfare", ""), "")
    const draw = Model.toastIconCommand("JetBrainsMono Nerd Font", "T", "#cdd6f4", "/state/fanfare/trumpet-cdd6f4.png")
    assert.ok(draw[2].includes("-rotate -45") && draw[2].includes("magick"))
    assert.deepStrictEqual(draw.slice(3), ["fanfare-icon", "JetBrainsMono Nerd Font", "T", "#cdd6f4", "/state/fanfare/trumpet-cdd6f4.png"])
    assert.deepStrictEqual(Model.toastIconCommand("x", "T", "#fff", "relative.png"), [])
    const withIcon = Model.toastCommand({ headline: "h" }, 0, "/state/fanfare/trumpet-cdd6f4.png")
    assert.deepStrictEqual(withIcon.slice(withIcon.indexOf("--image"), withIcon.indexOf("--image") + 2), ["--image", "/state/fanfare/trumpet-cdd6f4.png"])
    assert.ok(withIcon.includes("-g"))
    assert.ok(!Model.toastCommand({ headline: "h" }, 0, "").includes("--image"))
  },

  "the fanfare plays a local .ogg, quietly skipped under Do Not Disturb"() {
    const cmd = Model.soundCommand("file:///home/x/fanfare/sounds/fanfare.ogg")
    assert.deepStrictEqual(cmd.slice(0, 2), ["bash", "-c"])
    assert.ok(cmd[2].includes("dndState") && cmd[2].includes("pw-play"))
    assert.strictEqual(cmd[cmd.length - 1], "/home/x/fanfare/sounds/fanfare.ogg")
    assert.deepStrictEqual(Model.soundCommand("https://example.test/x.ogg"), [])
    assert.deepStrictEqual(Model.soundCommand("/tmp/x.wav"), [])
  },

  "day headings and relative times"() {
    const now = Date.parse("2026-10-08T15:00:00")
    assert.strictEqual(Model.dayLabel("2026-10-08T09:00:00", now), "Boosted today")
    assert.strictEqual(Model.dayLabel("2026-10-07T09:00:00", now), "Boosted yesterday")
    assert.strictEqual(Model.dayLabel("2026-10-05T09:00:00", now), "Boosted Monday")
    assert.strictEqual(Model.relativeTime(new Date(now - 5 * 60000).toISOString(), now), "5m ago")
  },

  "counts unseen boosts after a mark"() {
    const list = [{ id: "2", createdAt: "2026-10-08T11:00:00Z", bot: false }, { id: "1", createdAt: "2026-10-08T10:00:00Z", bot: true }]
    assert.strictEqual(Model.countSince(list, false, "2026-10-08T09:00:00Z"), 1)
    assert.strictEqual(Model.countSince(list, true, "2026-10-08T09:00:00Z"), 2)
    assert.strictEqual(Model.countSince(list, true, "2026-10-08T11:00:00Z"), 0)
  },

  "a lone emoji is the glyph; several quote them all; words get a speech bubble"() {
    assert.deepStrictEqual(Model.boostDisplay("❤️"), { glyph: "❤️", quote: "" })
    assert.deepStrictEqual(Model.boostDisplay(" 👍 "), { glyph: "👍", quote: "" })
    assert.deepStrictEqual(Model.boostDisplay("👏🏻👏🏻"), { glyph: "👏🏻", quote: "👏🏻👏🏻" })
    assert.deepStrictEqual(Model.boostDisplay("🕶️🤣"), { glyph: "🕶️", quote: "🕶️🤣" })
    assert.deepStrictEqual(Model.boostDisplay("of course!"), { glyph: "💬", quote: "of course!" })
    assert.deepStrictEqual(Model.boostDisplay("Wow!! 👏🏻👏🏻"), { glyph: "💬", quote: "Wow!! 👏🏻👏🏻" })
    assert.deepStrictEqual(Model.boostDisplay(""), { glyph: "", quote: "" })
  },

  "first glyph keeps joined emoji whole"() {
    assert.strictEqual(Model.firstGlyph("👨‍💻🎉"), "👨‍💻")
    assert.strictEqual(Model.firstGlyph("🇨🇦🇺🇸"), "🇨🇦")
    assert.strictEqual(Model.firstGlyph("1️⃣2️⃣"), "1️⃣")
    assert.strictEqual(Model.firstGlyph("👍🏾👍"), "👍🏾")
    assert.strictEqual(Model.firstGlyph("∞"), "∞")
  },

  "a boost is new when it is past its account's seen mark"() {
    const boost = { accountId: "7", createdAt: "2026-10-08T11:00:00Z" }
    assert.ok(Model.isUnseen(boost, { "7": "2026-10-08T10:00:00Z" }))
    assert.ok(!Model.isUnseen(boost, { "7": "2026-10-08T11:00:00Z" }))
    assert.ok(Model.isUnseen(boost, {}))
    assert.ok(!Model.isUnseen(null, {}))
  },

  "seen marks can be per account"() {
    const list = [
      { id: "7:2", accountId: "7", createdAt: "2026-10-08T11:00:00Z", bot: false },
      { id: "8:1", accountId: "8", createdAt: "2026-10-08T10:00:00Z", bot: false }
    ]
    assert.deepStrictEqual(Model.newestByAccount(list), { "7": "2026-10-08T11:00:00Z", "8": "2026-10-08T10:00:00Z" })
    assert.strictEqual(Model.countSince(list, false, { "7": "2026-10-08T09:00:00Z", "8": "2026-10-08T10:00:00Z" }), 1)
    assert.strictEqual(Model.countSince(list, false, {}), 2)
  },

  "toasts what is newer than its account's mark, never a first load"() {
    const list = [
      { id: "7:3", accountId: "7", createdAt: "2026-10-08T12:00:00Z", bot: false },
      { id: "7:2", accountId: "7", createdAt: "2026-10-08T11:00:00Z", bot: true },
      { id: "7:1", accountId: "7", createdAt: "2026-10-08T10:00:00Z", bot: false },
      { id: "8:1", accountId: "8", createdAt: "2026-10-08T13:00:00Z", bot: false }
    ]
    assert.deepStrictEqual(Model.boostsAfter(list, { "7": "2026-10-08T10:30:00Z" }, false).map(b => b.id), ["7:3"])
    assert.deepStrictEqual(Model.boostsAfter(list, { "7": "2026-10-08T10:30:00Z" }, true).map(b => b.id), ["7:3", "7:2"])
    assert.deepStrictEqual(Model.boostsAfter(list, {}, false), [])
  },

  "saved state round-trips per CLI home, timestamps only"() {
    let state = Model.withMarks({}, "", { "7": "2026-10-08T12:00:00Z" }, { "7": "2026-10-08T11:00:00Z" })
    state = Model.withMarks(state, "/dev/home", { "9": "2026-10-01T00:00:00Z" }, {})
    const reread = Model.parseState(Model.serializeState(state))
    assert.deepStrictEqual(Model.marksFor(reread, ""), { toasted: { "7": "2026-10-08T12:00:00Z" }, seen: { "7": "2026-10-08T11:00:00Z" } })
    assert.deepStrictEqual(Model.marksFor(reread, "/dev/home"), { toasted: { "9": "2026-10-01T00:00:00Z" }, seen: {} })
    // Replacing one home's marks leaves the other home alone.
    const replaced = Model.withMarks(reread, "", {}, {})
    assert.deepStrictEqual(Model.marksFor(replaced, ""), { toasted: {}, seen: {} })
    assert.deepStrictEqual(Model.marksFor(replaced, "/dev/home").toasted, { "9": "2026-10-01T00:00:00Z" })
    assert.deepStrictEqual(Model.parseState("not json"), {})
    assert.deepStrictEqual(Model.parseState(JSON.stringify({ accounts: { "x|1": { toasted: 5, seen: "" } } })), {})
  },

  "initials skip parenthetical labels"() {
    assert.strictEqual(Model.initials("RZ (agent)"), "R")
    assert.strictEqual(Model.initials("Grace Hopper"), "GH")
    assert.strictEqual(Model.initials(""), "?")
  }
}

let failed = 0
for (const [name, fn] of Object.entries(tests)) {
  try {
    fn()
    console.log("ok   " + name)
  } catch (error) {
    failed++
    console.log("FAIL " + name + "\n     " + error.message)
  }
}
console.log(`\n${Object.keys(tests).length - failed}/${Object.keys(tests).length} passed`)
process.exit(failed ? 1 : 0)
