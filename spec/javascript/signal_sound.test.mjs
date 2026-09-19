import test from "node:test"
import assert from "node:assert/strict"
import { SignalSound } from "../../app/javascript/signal_sound.js"

function setup() {
  let id = 10, chimes = 0, loads = 0
  const context = { state: "suspended", async resume() { this.state = "running" }, async suspend() { this.state = "suspended" } }
  const sound = new SignalSound({ createContext: () => context, loadLatest: async () => { loads++; return id } })
  sound.play = () => chimes++
  return { sound, context, setId: value => { id = value }, chimes: () => chimes, loads: () => loads }
}

test("enabling unlocks audio synchronously and snapshots old events; new batches sound once", async () => {
  const s = setup()
  const enabling = s.sound.enable()
  assert.equal(s.context.state, "running")
  await enabling
  assert.equal(s.chimes(), 1) // Deliberate confirmation tone.
  await s.sound.check()
  assert.equal(s.chimes(), 1)
  s.setId(15)
  await s.sound.check()
  await s.sound.check()
  assert.equal(s.chimes(), 2)
  s.setId(12) // Deletions or stale responses must not rewind the cursor.
  await s.sound.check()
  s.setId(15)
  await s.sound.check()
  assert.equal(s.chimes(), 2)
})

test("muting stops polling and skips events received while muted", async () => {
  const s = setup()
  await s.sound.enable()
  s.sound.disable()
  const loads = s.loads()
  s.setId(30)
  await s.sound.check()
  assert.equal(s.loads(), loads)
  await s.sound.enable()
  await s.sound.check()
  assert.equal(s.chimes(), 2) // Only the two enabling tones.
})

test("overlapping polls and an in-flight response after muting cannot play a tone", async () => {
  const s = setup()
  await s.sound.enable()
  let resolve, loads = 0
  s.sound.loadLatest = () => { loads++; return new Promise(done => { resolve = done }) }
  const pending = s.sound.check()
  await s.sound.check()
  assert.equal(loads, 1)
  s.sound.disable()
  resolve(99)
  await pending
  assert.equal(s.chimes(), 1)
  assert.equal(s.sound.enabled, false)
})

test("network failures and suspended audio do not consume new events", async () => {
  const s = setup()
  await s.sound.enable()
  s.sound.loadLatest = async () => { throw new Error("offline") }
  await s.sound.check()
  assert.equal(s.sound.lastId, 10)
  assert.equal(s.sound.error, "offline")
  s.sound.loadLatest = async () => 20
  s.context.state = "suspended"
  await s.sound.check()
  assert.equal(s.sound.lastId, 10)
  s.context.state = "running"
  await s.sound.check()
  assert.equal(s.chimes(), 2)
  assert.equal(s.sound.error, "")
})

test("autoplay rejection leaves sound disabled without loading events", async () => {
  const s = setup()
  s.context.resume = async () => { throw new Error("blocked") }
  await s.sound.enable()
  assert.equal(s.sound.enabled, false)
  assert.equal(s.sound.enabling, false)
  assert.equal(s.loads(), 0)
  assert.equal(s.chimes(), 0)
})

test("chime schedules two short quiet tones and releases audio nodes", () => {
  const tones = [], gains = []
  const sound = new SignalSound({})
  sound.context = {
    currentTime: 5, destination: {},
    createOscillator() {
      const tone = { frequency: {}, connect() {}, disconnect() { this.disconnected = true }, start(time) { this.startTime = time }, stop(time) { this.stopTime = time } }
      tones.push(tone)
      return tone
    },
    createGain() {
      const gain = { gain: { setValueAtTime() {}, linearRampToValueAtTime(value) { assert.equal(value, 0.08) }, exponentialRampToValueAtTime() {} }, connect() {}, disconnect() { this.disconnected = true } }
      gains.push(gain)
      return gain
    }
  }
  sound.play()
  assert.deepEqual(tones.map(t => t.frequency.value), [660, 880])
  assert.deepEqual(tones.map(t => t.startTime), [5, 5.18])
  for (const tone of tones) { assert.ok(tone.stopTime > tone.startTime); tone.onended(); assert.equal(tone.disconnected, true) }
  assert.ok(gains.every(g => g.disconnected))
})

function storedSetup(value = "off", options = {}) {
  const saved = new Map([["stock-screener:signal-sound", value]])
  const storage = { getItem: key => saved.get(key), setItem: (key, value) => saved.set(key, value) }
  let chimes = 0
  const context = { state: "suspended", async resume() { this.state = "running" }, async suspend() { this.state = "suspended" } }
  const sound = new SignalSound({ storage, createContext: () => context, loadLatest: async () => 20, ...options })
  sound.play = () => chimes++
  return { sound, context, storage, saved, chimes: () => chimes }
}

test("reload restores the saved preference silently and starts from current events", async () => {
  const first = storedSetup()
  await first.sound.enable()
  assert.equal(first.saved.get("stock-screener:signal-sound"), "on")
  const reload = storedSetup("off", { storage: first.storage })
  await reload.sound.restore()
  assert.equal(reload.sound.enabled, true)
  assert.equal(reload.sound.lastId, 20)
  assert.equal(reload.chimes(), 0)
  reload.sound.loadLatest = async () => 21
  await reload.sound.check()
  assert.equal(reload.chimes(), 1)
  await reload.sound.restore() // Turbo reconnect must not reset the cursor.
  assert.equal(reload.sound.lastId, 21)
  reload.sound.disable()
  const mutedReload = storedSetup("off", { storage: first.storage })
  await mutedReload.sound.restore()
  assert.equal(mutedReload.sound.enabled, false)
  assert.equal(mutedReload.sound.context, undefined)
})

test("pending autoplay permission times out to a clickable recovery without losing preference", async () => {
  const s = storedSetup("on", { resumeTimeoutMs: 5 })
  s.context.resume = () => new Promise(() => {})
  await s.sound.restore()
  assert.equal(s.sound.enabling, false)
  assert.equal(s.sound.enabled, false)
  assert.equal(s.sound.needsGesture, true)
  assert.equal(s.saved.get("stock-screener:signal-sound"), "on")
  s.context.resume = async () => { s.context.state = "running" }
  await s.sound.enable()
  assert.equal(s.sound.enabled, true)
  assert.equal(s.sound.needsGesture, false)
  assert.equal(s.chimes(), 1)
})

test("a rejected autoplay attempt keeps the saved setting and offers recovery", async () => {
  const s = storedSetup("on")
  s.context.resume = async () => { throw new Error("NotAllowedError") }
  await s.sound.restore()
  assert.equal(s.sound.needsGesture, true)
  assert.equal(s.sound.enabling, false)
  assert.equal(s.saved.get("stock-screener:signal-sound"), "on")
})

test("unavailable storage does not break manual sound controls", async () => {
  const s = storedSetup("off", { storage: { getItem() { throw new Error("denied") }, setItem() { throw new Error("denied") } } })
  await s.sound.restore()
  assert.equal(s.sound.enabled, true)
  await s.sound.enable()
  assert.equal(s.sound.enabled, true)
  s.sound.disable()
  assert.equal(s.sound.enabled, false)
})

test("muting during automatic restore cannot be undone by a late audio response", async () => {
  const s = storedSetup("on", { resumeTimeoutMs: 5 })
  s.context.resume = () => new Promise(() => {})
  const restoring = s.sound.restore()
  s.sound.disable()
  await restoring
  assert.equal(s.sound.enabled, false)
  assert.equal(s.sound.needsGesture, false)
  assert.equal(s.saved.get("stock-screener:signal-sound"), "off")
})


test("sound is on by default when no preference has been saved", async () => {
  const s = storedSetup(null)
  assert.equal(s.sound.wanted, true)
  await s.sound.restore()
  assert.equal(s.sound.enabled, true)
  assert.equal(s.chimes(), 0)
})

test("an ordinary interaction unlocks blocked sound silently but never overrides mute", async () => {
  const s = storedSetup(null, { resumeTimeoutMs: 5 })
  s.context.resume = () => new Promise(() => {})
  await s.sound.restore()
  assert.equal(s.sound.needsGesture, true)
  s.context.resume = async () => { s.context.state = "running" }
  await s.sound.activateFromGesture()
  assert.equal(s.sound.enabled, true)
  assert.equal(s.sound.needsGesture, false)
  assert.equal(s.chimes(), 0)
  s.sound.disable()
  await s.sound.activateFromGesture()
  assert.equal(s.sound.enabled, false)
  assert.equal(s.context.state, "suspended")
})

test("a click during pending automatic restoration can unlock audio immediately", async () => {
  const s = storedSetup(null, { resumeTimeoutMs: 5 })
  s.context.resume = () => new Promise(() => {})
  const restoring = s.sound.restore()
  s.context.resume = async () => { s.context.state = "running" }
  await s.sound.activateFromGesture()
  await restoring
  assert.equal(s.sound.enabled, true)
  assert.equal(s.sound.needsGesture, false)
  assert.equal(s.chimes(), 0)
})
