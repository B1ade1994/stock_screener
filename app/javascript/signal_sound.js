// One instance per browser document; Turbo navigation keeps its audio permission and cursor.
export class SignalSound {
  constructor({ loadLatest, createContext, storage, resumeTimeoutMs = 1500 }) {
    this.storage = storage
    this.resumeTimeoutMs = resumeTimeoutMs
    this.preferenceKey = "stock-screener:signal-sound"
    try { this.wanted = storage?.getItem(this.preferenceKey) !== "off" } catch { this.wanted = true }
    this.restored = false
    this.needsGesture = false
    this.loadLatest = loadLatest
    this.createContext = createContext
    this.enabled = false
    this.enabling = false
    this.pending = false
    this.lastId = null
    this.revision = 0
    this.error = ""
  }

  restore() {
    if (this.restored) return
    this.restored = true
    if (this.wanted) return this.enable({ automatic: true })
  }

  activateFromGesture() {
    if (!this.wanted || !this.context || this.context.state === "running") return
    return this.enable({ automatic: true })
  }

  savePreference(value) {
    this.wanted = value
    try { this.storage?.setItem(this.preferenceKey, value ? "on" : "off") } catch { /* Storage may be unavailable in private/restricted browsing. */ }
  }

  async resumeAudio() {
    let timer
    try {
      // Autoplay blocking can leave resume() pending indefinitely.
      await Promise.race([
        this.context.resume(),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Нажмите, чтобы восстановить звук")), this.resumeTimeoutMs) })
      ])
      if (this.context.state !== "running") throw new Error("Нажмите, чтобы восстановить звук")
    } finally { clearTimeout(timer) }
  }

  async enable({ automatic = false } = {}) {
    const revision = ++this.revision
    this.savePreference(true)
    this.needsGesture = false
    this.enabling = true
    this.error = ""
    this.changed()
    let audioReady = false
    try {
      // Must run before the first await, while the user's click is still active.
      this.context ||= this.createContext()
      await this.resumeAudio()
      if (revision !== this.revision) return
      audioReady = true
      const id = this.validId(await this.loadLatest())
      if (revision !== this.revision) return
      this.lastId = id // Existing events, including events received while muted, are silent.
      this.enabled = true
      if (!automatic) this.play()
    } catch (error) {
      if (revision !== this.revision) return
      this.enabled = false
      this.needsGesture = Boolean(this.context) && !audioReady
      this.error = error.message || "Не удалось включить звук"
    } finally {
      if (revision === this.revision) { this.enabling = false; this.changed() }
    }
  }

  disable() {
    this.savePreference(false)
    this.needsGesture = false
    this.revision++
    this.enabled = false
    this.enabling = false
    this.lastId = null
    this.error = ""
    this.context?.suspend().catch(() => {})
    this.changed()
  }

  async check() {
    if (!this.enabled || this.pending || this.enabling) return
    const revision = this.revision
    this.pending = true
    try {
      const id = this.validId(await this.loadLatest())
      if (revision !== this.revision) return
      if (this.context.state !== "running") {
        this.needsGesture = true
        this.error = "Браузер приостановил звук. Нажмите, чтобы включить снова."
        return
      }
      this.needsGesture = false
      this.error = ""
      if (id > this.lastId) this.play() // A batch of new events produces just one chime.
      this.lastId = Math.max(this.lastId, id) // Deletions and stale responses never move the cursor back.
    } catch (error) {
      if (revision === this.revision) this.error = error.message || "Не удалось проверить события"
    } finally {
      this.pending = false
      this.changed()
    }
  }

  validId(id) {
    if (!Number.isSafeInteger(id) || id < 0) throw new Error("Некорректный ответ сервера событий")
    return id
  }

  play() {
    const start = this.context.currentTime
    ;[660, 880].forEach((frequency, index) => {
      const oscillator = this.context.createOscillator()
      const gain = this.context.createGain()
      const time = start + index * 0.18
      oscillator.type = "sine"
      oscillator.frequency.value = frequency
      gain.gain.setValueAtTime(0, time)
      gain.gain.linearRampToValueAtTime(0.08, time + 0.015)
      gain.gain.exponentialRampToValueAtTime(0.001, time + 0.14)
      oscillator.connect(gain)
      gain.connect(this.context.destination)
      oscillator.onended = () => { oscillator.disconnect(); gain.disconnect() }
      oscillator.start(time)
      oscillator.stop(time + 0.15)
    })
  }

  changed() { this.onChange?.() }
}
