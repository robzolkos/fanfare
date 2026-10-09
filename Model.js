// Pure data helpers for the Fanfare plugin. Loaded by QML (`import "Model.js"
// as Model`) and by the node tests through the module.exports guard at the end.

// Basecamp's /my/boosts.json serves only your latest 200 boosts, in geared
// pages of 15, 30, 50, 100.
var boostLimit = 200
var maxPages = 6

// Excerpts cost one request each, fetched one at a time; this caps how many
// boosted comments a single pass will fetch.
var excerptFetchLimit = 60
var excerptLength = 180

var toastMaxNames = 3

function cleanText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").trim()
  var max = limit || 200
  return text.length > max ? text.substring(0, max - 1) + "…" : text
}

function parseJson(text) {
  try {
    return { ok: true, value: JSON.parse(String(text || "")) }
  } catch (error) {
    return { ok: false, error: "Could not parse the Basecamp CLI response" }
  }
}

// Agents (and anything else that is not a person) count as bots. People are
// `User`, or `Client` for client-side people.
function isBot(personableType) {
  var type = String(personableType || "")
  return type !== "User" && type !== "Client"
}

function isChatLine(type) {
  return String(type || "").indexOf("Chat::Lines::") === 0
}

// Things that live inside something else are described by that something: a
// comment by its card, a chat line by its chat. A card or message boosted
// directly describes itself (its parent is only a column or the message board).
function livesInParent(type) {
  return type === "Comment" || type === "Question::Answer" || isChatLine(type)
}

// What a boost was on, phrased the way Basecamp phrases it: the card,
// question or chat it lives in. `self` marks a thing boosted directly, whose
// own title is the excerpt.
function subjectFor(recording) {
  var rec = recording || {}
  var type = String(rec.type || "")
  var parent = rec.parent || {}
  var parentTitle = cleanText(parent.title, 160)
  var ownTitle = cleanText(rec.title, 160)
  var project = cleanText(rec.bucket ? rec.bucket.name : "", 80)

  // A recurring check-in asks the same question every day, so the answer is
  // dated to say which day's it was.
  if (type === "Question::Answer") {
    var answered = shortDate(rec.created_at)
    return {
      title: (parentTitle || ownTitle) + (answered ? " · " + answered : ""),
      kind: "Check-in",
      project: project,
      self: false
    }
  }

  if (livesInParent(type) && parent.id !== undefined && parent.id !== null) {
    var info = { project: project, self: false }
    if (type === "Comment") {
      info.title = parentTitle || ownTitle.replace(/^Re:\s*/, "")
      info.kind = "Comment"
    } else if (parentTitle === "Ping") {
      // A ping's project is named for the people in it.
      info.title = "Ping with " + project
      info.kind = "Ping"
      info.project = ""
    } else {
      info.title = (parentTitle && parentTitle !== "Chat" ? parentTitle : "Chat")
      info.kind = "Chat"
    }
    return info
  }

  var kinds = { "Message": "Message", "Kanban::Card": "Card", "Todo": "To-do", "Document": "Document", "Upload": "File" }
  return {
    title: ownTitle || parentTitle || "Something you made",
    kind: kinds[type] || type.replace(/::/g, " "),
    project: project,
    self: true
  }
}

// A chat line's title is its text; other boosted things need their content
// fetched (see excerptTargets).
function inlineExcerpt(recording) {
  var rec = recording || {}
  var type = String(rec.type || "")
  if (type === "Chat::Lines::Upload") return "📎 " + cleanText(rec.title, excerptLength)
  if (isChatLine(type)) return cleanText(rec.title, excerptLength)
  return ""
}

function needsFetchedExcerpt(type) {
  return type === "Comment" || type === "Question::Answer"
}

// `account` ({ id, name }) tags the boost with where it came from; its id
// also prefixes the boost's key so boosts from two accounts never collide.
function normalizeBoost(raw, account) {
  if (!raw || raw.id === undefined || raw.id === null) return null
  var booster = raw.booster || {}
  var recording = raw.recording || {}
  var subject = subjectFor(recording)
  var accountId = account && account.id !== undefined && account.id !== null ? String(account.id) : ""
  return {
    id: (accountId ? accountId + ":" : "") + String(raw.id),
    accountId: accountId,
    accountName: account ? cleanText(account.name, 80) : "",
    content: cleanText(raw.content, 40),
    createdAt: String(raw.created_at || ""),
    boosterId: String(booster.id || ""),
    boosterName: cleanText(booster.name, 80) || "Someone",
    boosterAvatar: String(booster.avatar_url || ""),
    bot: isBot(booster.personable_type),
    recordingId: String(recording.id || ""),
    recordingType: String(recording.type || ""),
    recordingApiUrl: String(recording.url || ""),
    url: String(recording.app_url || ""),
    excerpt: inlineExcerpt(recording),
    selfEntry: subject.self === true,
    title: subject.title,
    kind: subject.kind,
    project: subject.project
  }
}

// One `basecamp api get /my/boosts.json?page=N --account ID --json` response.
function parsePage(text, account) {
  var parsed = parseJson(text)
  if (!parsed.ok) return { ok: false, error: parsed.error, code: "", boosts: [] }
  var envelope = parsed.value || {}
  if (envelope.ok === false)
    return { ok: false, error: cleanText(envelope.error || "The Basecamp CLI request failed", 180), code: String(envelope.code || ""), boosts: [] }
  var data = Array.isArray(envelope) ? envelope : envelope.data
  if (!Array.isArray(data)) return { ok: false, error: "Unexpected response from /my/boosts", code: "", boosts: [] }
  var boosts = []
  for (var i = 0; i < data.length; i++) {
    var boost = normalizeBoost(data[i], account)
    if (boost) boosts.push(boost)
  }
  return { ok: true, error: "", code: "", boosts: boosts }
}

function idSet(boosts) {
  var set = {}
  for (var i = 0; i < (boosts || []).length; i++) set[boosts[i].id] = true
  return set
}

function newestFirst(a, b) {
  if (a.createdAt === b.createdAt) return Number(b.id) - Number(a.id)
  return a.createdAt < b.createdAt ? 1 : -1
}

// An incremental refresh walks pages only while every boost on the page is
// new to us: the first page that overlaps what we hold means we've caught up.
function wantsNextPage(pageBoosts, known, page, fullReload) {
  if (!pageBoosts || pageBoosts.length === 0) return false
  if (page >= maxPages) return false
  if (fullReload) return true
  for (var i = 0; i < pageBoosts.length; i++) {
    if (known[pageBoosts[i].id]) return false
  }
  return true
}

// A full reload replaces what we hold (it also drops unboosted items); an
// incremental one adds the fresh page(s) on top. Each account keeps its own
// latest boostLimit, as Basecamp serves them; `accountIds`, when given, drops
// boosts from accounts no longer watched.
function mergeBoosts(existing, fetched, fullReload, accountIds) {
  var byId = {}
  var source = fullReload ? fetched : (existing || []).concat(fetched || [])
  var watched = null
  if (Array.isArray(accountIds)) {
    watched = {}
    for (var w = 0; w < accountIds.length; w++) watched[String(accountIds[w])] = true
  }
  for (var i = 0; i < source.length; i++) {
    if (watched && !watched[source[i].accountId || ""]) continue
    byId[source[i].id] = source[i]
  }
  var merged = []
  for (var id in byId) merged.push(byId[id])
  merged.sort(newestFirst)
  var perAccount = {}
  var kept = []
  for (var k = 0; k < merged.length; k++) {
    var key = merged[k].accountId || ""
    perAccount[key] = (perAccount[key] || 0) + 1
    if (perAccount[key] <= boostLimit) kept.push(merged[k])
  }
  return kept
}

// `basecamp accounts list --json`: every account this login can reach.
function parseAccounts(text) {
  var parsed = parseJson(text)
  if (!parsed.ok) return { ok: false, error: parsed.error, accounts: [] }
  var envelope = parsed.value || {}
  if (envelope.ok === false) return { ok: false, error: cleanText(envelope.error || "Could not list Basecamp accounts", 180), code: String(envelope.code || ""), accounts: [] }
  var data = Array.isArray(envelope) ? envelope : envelope.data
  if (!Array.isArray(data)) return { ok: false, error: "Unexpected response from basecamp accounts list", accounts: [] }
  var accounts = []
  for (var i = 0; i < data.length; i++) {
    if (!data[i] || data[i].id === undefined || data[i].id === null) continue
    accounts.push({ id: String(data[i].id), name: cleanText(data[i].name, 80) || String(data[i].id) })
  }
  return { ok: true, error: "", accounts: accounts }
}

// `basecamp auth status --json`: the CLI's default account, if it has one.
function parseDefaultAccountId(text) {
  var parsed = parseJson(text)
  if (!parsed.ok || !parsed.value || !parsed.value.data) return ""
  var id = parsed.value.data.account_id
  return id === undefined || id === null ? "" : String(id)
}

// The accounts probe's output: auth status, the separator, the account list.
function parseAccountsProbe(text) {
  var source = String(text || "")
  var at = source.indexOf("\n--accounts--\n")
  if (at < 0) return { ok: false, error: "Could not read the Basecamp CLI's accounts", defaultId: "", accounts: [] }
  var listed = parseAccounts(source.substring(at + "\n--accounts--\n".length))
  return { ok: listed.ok, error: listed.error, code: listed.code || "", defaultId: parseDefaultAccountId(source.substring(0, at)), accounts: listed.accounts }
}

// The accounts to watch: those picked in settings that this login can still
// reach, or — when nothing (reachable) is picked — the CLI's default account,
// or failing that the first one.
// Settings arrive as a real JS array after a live edit but as a Qt list (not
// Array.isArray) when the shell starts, so take anything list-shaped.
function listOf(value) {
  if (value === undefined || value === null || typeof value === "string") return null
  if (Array.isArray(value)) return value
  if (typeof value.length === "number") {
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
  }
  return null
}

function watchedAccounts(setting, accounts, defaultId) {
  var all = accounts || []
  var picked = []
  var list = listOf(setting)
  if (list) {
    var wanted = {}
    for (var i = 0; i < list.length; i++) wanted[String(list[i])] = true
    for (var a = 0; a < all.length; a++) if (wanted[all[a].id]) picked.push(all[a])
  }
  if (picked.length > 0) return picked
  for (var d = 0; d < all.length; d++) if (all[d].id === String(defaultId || "")) return [all[d]]
  return all.length > 0 ? [all[0]] : []
}

function visibleBoosts(boosts, showBots) {
  var out = []
  for (var i = 0; i < (boosts || []).length; i++) {
    if (showBots || !boosts[i].bot) out.push(boosts[i])
  }
  return out
}

// The line under a boost: where the boosted thing lives. A comment is "On"
// its card, a chat line "In" its chat; a thing boosted directly is already the
// excerpt, so its line just says what kind of thing it is.
function contextLine(boost) {
  if (!boost) return ""
  var place = boost.kind
  if (!boost.selfEntry) {
    var prefix = boost.kind === "Comment" ? "On " : (boost.kind === "Chat" || boost.kind === "Ping") ? "In " : ""
    place = prefix + boost.title
  }
  return [place, boost.project].filter(function(part) { return part }).join(" · ")
}

// The comments and answers in the feed whose text we haven't fetched (or
// failed to), newest first, each once, capped.
function excerptTargets(boosts, excerpts, failed, limit) {
  var have = excerpts || {}
  var skip = failed || {}
  var max = limit || excerptFetchLimit
  var queued = {}
  var out = []
  for (var i = 0; i < (boosts || []).length && out.length < max; i++) {
    var boost = boosts[i]
    var id = boost.recordingId
    if (!needsFetchedExcerpt(boost.recordingType) || queued[id]) continue
    if (have[id] !== undefined || skip[id]) continue
    if (!/^https:\/\/[^\s]+\.json$/.test(boost.recordingApiUrl)) continue
    queued[id] = true
    out.push({ recordingId: id, apiUrl: boost.recordingApiUrl, accountId: boost.accountId || "" })
  }
  return out
}

function decodeEntities(text) {
  return String(text || "")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, function(_, code) { return String.fromCharCode(Number(code)) })
    .replace(/&amp;/g, "&")
}

// Basecamp rich text to one line: mentions become @Name, other attachments
// their caption (or a paperclip), blocks become spaces, and tags go.
function htmlToText(html, limit) {
  var text = String(html || "")
  text = text.replace(/<bc-attachment\b([^>]*)>([\s\S]*?)<\/bc-attachment>/gi, function(_, attrs, inner) {
    var caption = (/<figcaption[^>]*>([\s\S]*?)<\/figcaption>/i.exec(inner) || [])[1] || ""
    caption = cleanText(caption.replace(/<[^>]+>/g, ""), 80)
    if (/content-type="[^"]*mention/i.test(attrs)) return " @" + (caption || "someone") + " "
    return caption ? " 📎 " + caption + " " : " 📎 "
  })
  text = text.replace(/<(br|\/p|\/div|\/li|\/h\d|\/blockquote|\/pre)\b[^>]*>/gi, " ")
  text = text.replace(/<[^>]+>/g, "")
  return cleanText(decodeEntities(text), limit || excerptLength)
}

// `basecamp api get <url> --jq '{content: .data.content}'`: wrapping the string
// in an object keeps the CLI from printing it raw.
function parseExcerpt(text) {
  var parsed = parseJson(text)
  if (!parsed.ok || !parsed.value || typeof parsed.value.content !== "string") return { ok: false, text: "" }
  return { ok: true, text: htmlToText(parsed.value.content) }
}

// The first emoji in a string, as one visible glyph: a code point plus what
// joins onto it — variation selectors, skin tones, keycaps, tags, a
// zero-width joiner and the next code point, or a flag's second regional
// indicator. Enough for boosts; not a full grapheme segmenter.
function firstGlyph(text) {
  var str = String(text || "")
  if (str === "") return ""
  var i = 0
  function next() {
    var code = str.codePointAt(i)
    i += code > 0xFFFF ? 2 : 1
    return code
  }
  var first = next()
  var regional = first >= 0x1F1E6 && first <= 0x1F1FF
  if (regional && i < str.length) {
    var second = str.codePointAt(i)
    if (second >= 0x1F1E6 && second <= 0x1F1FF) next()
  }
  while (i < str.length) {
    var code = str.codePointAt(i)
    var joins = code === 0xFE0E || code === 0xFE0F || code === 0x20E3
      || (code >= 0x1F3FB && code <= 0x1F3FF)
      || (code >= 0xE0020 && code <= 0xE007F)
    if (joins) { next(); continue }
    if (code === 0x200D) {
      next()
      if (i < str.length) next()
      continue
    }
    break
  }
  return str.substring(0, i)
}

// How a boost shows: a lone emoji is the glyph and nothing else; several
// emoji show the first as the glyph and quote them all; words show a speech
// bubble and quote the words.
function boostDisplay(content) {
  var text = String(content || "").trim()
  if (text === "") return { glyph: "", quote: "" }
  if (/[A-Za-z0-9]/.test(text)) return { glyph: "💬", quote: text }
  var first = firstGlyph(text)
  return first === text ? { glyph: text, quote: "" } : { glyph: first, quote: text }
}

// Boosts newer than their account's toasted mark: what a refresh should toast.
// An account with no mark is loading for the first time, which never toasts.
function boostsAfter(boosts, marks, showBots) {
  var out = []
  var map = marks || {}
  for (var i = 0; i < (boosts || []).length; i++) {
    var boost = boosts[i]
    if (!showBots && boost.bot) continue
    var mark = map[boost.accountId || ""]
    if (!mark) continue
    if (boost.createdAt > mark) out.push(boost)
  }
  out.sort(newestFirst)
  return out
}

// Saved state: per CLI home and account, how far boosts have been toasted and
// seen — timestamps only, never boost content — so a restart picks up where
// it left off instead of treating everything as already seen.
function stateKey(home, accountId) {
  return (home || "default") + "|" + String(accountId || "")
}

function parseState(text) {
  var parsed = parseJson(text)
  var accounts = parsed.ok && parsed.value && typeof parsed.value.accounts === "object" && parsed.value.accounts ? parsed.value.accounts : {}
  var clean = {}
  for (var key in accounts) {
    var entry = accounts[key] || {}
    var toasted = typeof entry.toasted === "string" ? entry.toasted : ""
    var seen = typeof entry.seen === "string" ? entry.seen : ""
    if (toasted || seen) clean[key] = { toasted: toasted, seen: seen }
  }
  return clean
}

function serializeState(accounts) {
  return JSON.stringify({ version: 1, accounts: accounts || {} }, null, 2) + "\n"
}

// One home's marks out of the saved state, as { accountId: iso } maps.
function marksFor(state, home) {
  var prefix = (home || "default") + "|"
  var toasted = {}
  var seen = {}
  for (var key in (state || {})) {
    if (key.indexOf(prefix) !== 0) continue
    var id = key.substring(prefix.length)
    if (state[key].toasted) toasted[id] = state[key].toasted
    if (state[key].seen) seen[id] = state[key].seen
  }
  return { toasted: toasted, seen: seen }
}

// The saved state with one home's marks replaced.
function withMarks(state, home, toasted, seen) {
  var prefix = (home || "default") + "|"
  var next = {}
  for (var key in (state || {})) if (key.indexOf(prefix) !== 0) next[key] = state[key]
  var ids = {}
  for (var a in (toasted || {})) ids[a] = true
  for (var b in (seen || {})) ids[b] = true
  for (var id in ids) next[stateKey(home, id)] = { toasted: (toasted || {})[id] || "", seen: (seen || {})[id] || "" }
  return next
}

// Whether a boost is newer than the seen mark. `marks` is one ISO time for
// every boost, or a map of account id to ISO time, so an account joining the
// wall can start out seen without hiding anything new elsewhere. No mark
// means nothing has been seen yet.
function isUnseen(boost, marks) {
  if (!boost) return false
  var since = marks && typeof marks === "object" ? String(marks[boost.accountId || ""] || "") : String(marks || "")
  return since === "" || boost.createdAt > since
}

// How many boosts are unseen — the trumpet's count; the panel rings the same ones.
function countSince(boosts, showBots, marks) {
  var count = 0
  for (var i = 0; i < (boosts || []).length; i++) {
    if (!showBots && boosts[i].bot) continue
    if (isUnseen(boosts[i], marks)) count++
  }
  return count
}

// Each account's newest boost time, as { accountId: iso }.
function newestByAccount(boosts) {
  var newest = {}
  for (var i = 0; i < (boosts || []).length; i++) {
    var key = boosts[i].accountId || ""
    if (!newest[key] || boosts[i].createdAt > newest[key]) newest[key] = boosts[i].createdAt
  }
  return newest
}

function newestCreatedAt(boosts) {
  var newest = ""
  for (var i = 0; i < (boosts || []).length; i++) {
    if (boosts[i].createdAt > newest) newest = boosts[i].createdAt
  }
  return newest
}

function firstName(name) {
  return String(name || "").split(" ")[0] || "Someone"
}

function initials(name) {
  var parts = String(name || "").replace(/\(.*?\)/g, "").trim().split(/\s+/)
  var letters = ""
  for (var i = 0; i < parts.length && letters.length < 2; i++) {
    if (parts[i]) letters += parts[i].charAt(0).toUpperCase()
  }
  return letters || "?"
}

// One toast per refresh: "Ada Lovelace boosted ❤️" on one boost, a count with
// the first few people on more. Clicking opens the newest boosted thing.
function composeToast(boosts) {
  var list = boosts || []
  if (list.length === 0) return null
  var newest = list[0]
  if (list.length === 1) {
    return {
      headline: newest.boosterName + " boosted " + newest.content,
      // A chat line's own words say more than "Chat"; otherwise the title.
      description: newest.excerpt || newest.title,
      url: newest.url
    }
  }
  var parts = []
  for (var i = 0; i < list.length && i < toastMaxNames; i++)
    parts.push(list[i].content + " " + firstName(list[i].boosterName))
  var more = list.length - parts.length
  return {
    headline: list.length + " new boosts",
    description: parts.join(", ") + (more > 0 ? " and " + more + " more" : ""),
    url: newest.url
  }
}

function parseTime(iso) {
  var ms = Date.parse(String(iso || ""))
  return isFinite(ms) ? ms : 0
}

function relativeTime(iso, nowMs) {
  var ms = parseTime(iso)
  if (ms <= 0) return ""
  var seconds = Math.max(0, Math.round((Number(nowMs) - ms) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.round(hours / 24)
  if (days < 7) return days + "d ago"
  var date = new Date(ms)
  return months[date.getMonth()].substring(0, 3) + " " + date.getDate()
}

var weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

// "Oct 8", in local time.
function shortDate(iso) {
  var ms = parseTime(iso)
  if (ms <= 0) return ""
  var date = new Date(ms)
  return months[date.getMonth()].substring(0, 3) + " " + date.getDate()
}

function localDayKey(ms) {
  var date = new Date(ms)
  return date.getFullYear() + "-" + (date.getMonth() + 1) + "-" + date.getDate()
}

// "Boosted today", "Boosted yesterday", "Boosted Monday", then dates — the
// headings Basecamp's My Boosts page puts between days.
function dayLabel(iso, nowMs) {
  var ms = parseTime(iso)
  if (ms <= 0) return ""
  var now = new Date(Number(nowMs))
  var startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  var dayMs = 24 * 60 * 60 * 1000
  if (ms >= startOfToday) return "Boosted today"
  if (ms >= startOfToday - dayMs) return "Boosted yesterday"
  var date = new Date(ms)
  if (ms >= startOfToday - 6 * dayMs) return "Boosted " + weekdays[date.getDay()]
  return "Boosted " + months[date.getMonth()] + " " + date.getDate()
}

// The feed: boosts newest first, with a day heading wherever the day changes,
// as one flat list for a Repeater. `index` is the boost's place in the feed,
// for keyboard selection.
function feedRows(boosts, nowMs) {
  var rows = []
  var lastDay = ""
  for (var i = 0; i < (boosts || []).length; i++) {
    var boost = boosts[i]
    var ms = parseTime(boost.createdAt)
    var day = ms > 0 ? localDayKey(ms) : ""
    if (day !== lastDay) {
      rows.push({ header: true, label: dayLabel(boost.createdAt, nowMs) })
      lastDay = day
    }
    rows.push({ header: false, boost: boost, index: i })
  }
  return rows
}

// The mosaic: one section per local day, newest first, each holding its
// boosts with their place in the feed (for keyboard selection).
function daySections(boosts, nowMs) {
  var sections = []
  var current = null
  for (var i = 0; i < (boosts || []).length; i++) {
    var boost = boosts[i]
    var ms = parseTime(boost.createdAt)
    var day = ms > 0 ? localDayKey(ms) : ""
    if (!current || current.day !== day) {
      current = { day: day, label: dayLabel(boost.createdAt, nowMs).replace(/^Boosted /, ""), items: [] }
      sections.push(current)
    }
    current.items.push({ boost: boost, index: i })
  }
  for (var s = 0; s < sections.length; s++) {
    var label = sections[s].label
    sections[s].label = label.charAt(0).toUpperCase() + label.substring(1)
    sections[s].count = sections[s].items.length
  }
  return sections
}

// Arrow keys across laid-out items. `cells` are { index, row, col, span }:
// row is the item's visual row (ranked across every section), col and span
// its horizontal position and width in any unit. Left/right walk the feed
// order; up/down go to the item in the next row that overlaps this one's
// middle, or the nearest one.
function gridNeighbor(cells, fromIndex, dx, dy) {
  var list = cells || []
  if (list.length === 0) return fromIndex
  var current = null
  for (var i = 0; i < list.length; i++) if (list[i].index === fromIndex) current = list[i]
  if (!current) return list[0].index
  if (dy === 0) {
    var target = fromIndex + dx
    for (var j = 0; j < list.length; j++) if (list[j].index === target) return target
    return fromIndex
  }
  var middle = current.col + current.span / 2
  var rows = {}
  for (var k = 0; k < list.length; k++) rows[list[k].row] = true
  var row = current.row + dy
  var lastRow = 0
  for (var r in rows) lastRow = Math.max(lastRow, Number(r))
  while (row >= 0 && row <= lastRow && !rows[row]) row += dy
  if (row < 0 || row > lastRow) return fromIndex
  var best = null
  var bestDistance = Infinity
  for (var m = 0; m < list.length; m++) {
    var cell = list[m]
    if (cell.row !== row) continue
    var distance = middle >= cell.col && middle <= cell.col + cell.span ? 0 : Math.abs(cell.col + cell.span / 2 - middle)
    if (distance < bestDistance) { best = cell; bestDistance = distance }
  }
  return best ? best.index : fromIndex
}

function withAccount(command, accountId) {
  var id = String(accountId || "")
  return /^\d+$/.test(id) ? command.concat(["--account", id]) : command
}

function boostsPageCommand(page, accountId) {
  return withAccount(["timeout", "30", "basecamp", "api", "get", "/my/boosts.json?page=" + page, "--json"], accountId)
}

function accountsProbeCommand() {
  // bash always exits, so a missing CLI still ends the probe: the auth status
  // line, a separator, then the account list.
  return ["bash", "-c", "command -v basecamp >/dev/null 2>&1 || exit 127; timeout 30 basecamp auth status --json; printf '\\n--accounts--\\n'; timeout 30 basecamp accounts list --json"]
}

function excerptCommand(apiUrl, accountId) {
  return withAccount(["timeout", "20", "basecamp", "api", "get", String(apiUrl), "--jq", "{content: .data.content}"], accountId)
}

// Plays the fanfare unless notifications are on Do Not Disturb. `path` is a
// local file; anything else plays nothing.
function soundCommand(path) {
  var file = String(path || "").replace(/^file:\/\//, "")
  if (!/^\/[^\0]+\.ogg$/.test(file)) return []
  return ["bash", "-c", "[ \"$(omarchy-shell -q notifications dndState)\" = on ] || exec timeout 10 pw-play \"$1\"", "fanfare-sound", file]
}

// The toast's icon: the trumpet drawn from the bar's font at the bar's angle,
// in the notification text colour, as a PNG (a glyph can't be rotated in the
// toast). Made once per colour; an existing file is kept.
// A link Fanfare may open: https anywhere, plain http only on a .localhost
// development host. `rewrite` ({ from, to }) maps one prefix to another first,
// for development servers whose links point at the wrong host. Anything else
// opens nothing.
function openableUrl(url, rewrite) {
  var link = String(url || "")
  if (rewrite && rewrite.from && rewrite.to && link.indexOf(String(rewrite.from)) === 0)
    link = String(rewrite.to) + link.substring(String(rewrite.from).length)
  if (/^https:\/\/[^\s]+$/.test(link)) return link
  if (/^http:\/\/[a-z0-9.-]+\.localhost(:\d+)?\/[^\s]*$/i.test(link)) return link
  return ""
}

function toastIconPath(stateDir, color) {
  var hex = String(color || "").replace(/[^0-9a-fA-F]/g, "").toLowerCase()
  return hex ? String(stateDir) + "/trumpet-" + hex + ".png" : ""
}

function toastIconCommand(fontFamily, glyph, color, path) {
  if (!/^\/[^\0]+\.png$/.test(String(path || ""))) return []
  var script = "[ -s \"$4\" ] && exit 0; font=$(fc-match -f '%{file}' \"$1\") || exit 1; " +
    "exec timeout 20 magick -background none -fill \"$3\" -font \"$font\" -pointsize 160 label:\"$2\" " +
    "-trim +repage -rotate -45 -trim +repage -resize 72x72 -gravity center -extent 80x80 \"$4\""
  return ["bash", "-c", script, "fanfare-icon", String(fontFamily), String(glyph), String(color), String(path)]
}

function toastCommand(toast, replaceId, iconPath) {
  var command = [
    "omarchy-notification-send",
    "--app-name", "Fanfare",
    "-u", "low",
    "-g", "󱂖",
    "-p"
  ]
  // The angled trumpet when it's been drawn; the glyph stays as a fallback.
  if (/^\/[^\0]+\.png$/.test(String(iconPath || ""))) command.push("--image", String(iconPath))
  var id = Number(replaceId || 0)
  if (isFinite(id) && id > 0) command.push("-r", String(id))
  command.push(cleanText(toast.headline, 120))
  if (toast.description) command.push(cleanText(toast.description, 200))
  var link = openableUrl(toast.url)
  if (link) command.push("--exec", "xdg-open", link)
  return command
}

if (typeof module !== "undefined") {
  module.exports = {
    boostLimit: boostLimit,
    maxPages: maxPages,
    excerptFetchLimit: excerptFetchLimit,
    cleanText: cleanText,
    isBot: isBot,
    subjectFor: subjectFor,
    normalizeBoost: normalizeBoost,
    parsePage: parsePage,
    idSet: idSet,
    wantsNextPage: wantsNextPage,
    mergeBoosts: mergeBoosts,
    parseAccounts: parseAccounts,
    parseDefaultAccountId: parseDefaultAccountId,
    parseAccountsProbe: parseAccountsProbe,
    watchedAccounts: watchedAccounts,
    accountsProbeCommand: accountsProbeCommand,
    visibleBoosts: visibleBoosts,
    contextLine: contextLine,
    excerptTargets: excerptTargets,
    htmlToText: htmlToText,
    parseExcerpt: parseExcerpt,
    isUnseen: isUnseen,
    countSince: countSince,
    newestCreatedAt: newestCreatedAt,
    newestByAccount: newestByAccount,
    boostsAfter: boostsAfter,
    stateKey: stateKey,
    parseState: parseState,
    serializeState: serializeState,
    marksFor: marksFor,
    withMarks: withMarks,
    initials: initials,
    composeToast: composeToast,
    firstGlyph: firstGlyph,
    boostDisplay: boostDisplay,
    relativeTime: relativeTime,
    dayLabel: dayLabel,
    feedRows: feedRows,
    daySections: daySections,
    gridNeighbor: gridNeighbor,
    boostsPageCommand: boostsPageCommand,
    excerptCommand: excerptCommand,
    openableUrl: openableUrl,
    toastIconPath: toastIconPath,
    toastIconCommand: toastIconCommand,
    toastCommand: toastCommand,
    soundCommand: soundCommand
  }
}
