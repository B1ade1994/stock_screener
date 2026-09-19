import { Controller } from "@hotwired/stimulus"
import { SignalSound } from "signal_sound"

let sound

export default class extends Controller {
  static targets = ["button", "status"]
  static values = { url: String }

  connect() {
    const url = this.urlValue
    sound ||= new SignalSound({
      storage: {
        getItem: key => window.localStorage.getItem(key),
        setItem: (key, value) => window.localStorage.setItem(key, value)
      },
      createContext: () => {
        const AudioContext = window.AudioContext || window.webkitAudioContext
        if (!AudioContext) throw new Error("Браузер не поддерживает звуковые уведомления")
        return new AudioContext()
      },
      loadLatest: async () => {
        const abort = new AbortController()
        const timer = setTimeout(() => abort.abort(), 10000)
        try {
          const response = await fetch(url, { headers: { Accept: "application/json" }, cache: "no-store", signal: abort.signal })
          if (!response.ok) throw new Error("Не удалось проверить новые события")
          return (await response.json()).latest_id
        } catch {
          throw new Error("Нет связи с сервером событий")
        } finally { clearTimeout(timer) }
      }
    })
    this.onGesture = event => {
      if (!event.isTrusted || this.element.contains(event.target)) return
      sound.activateFromGesture()
    }
    document.addEventListener("click", this.onGesture)
    document.addEventListener("keydown", this.onGesture)
    this.onChange = () => this.render()
    sound.onChange = this.onChange
    this.render()
    sound.restore()
    sound.check()
    this.timer = setInterval(() => sound.check(), 5000)
  }

  disconnect() {
    clearInterval(this.timer)
    document.removeEventListener("click", this.onGesture)
    document.removeEventListener("keydown", this.onGesture)
    if (sound.onChange === this.onChange) sound.onChange = null
  }

  toggle() {
    if (sound.wanted) sound.disable()
    else sound.enable()
  }

  render() {
    const button = this.buttonTarget
    button.disabled = false
    button.setAttribute("aria-pressed", String(sound.wanted))
    button.setAttribute("aria-label", sound.wanted ? "Выключить звук" : "Включить звук")
    button.title = sound.wanted ? "Выключить звук новых событий" : "Включить звук новых событий. Прозвучит проверочный сигнал."
    this.statusTarget.textContent = sound.needsGesture ? "Звук начнётся после нажатия на страницу" : sound.error || (sound.enabling ? "Подключение звука…" : "")
    this.statusTarget.hidden = !this.statusTarget.textContent
  }
}
