import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { interval: Number }

  connect() {
    this.discardRefresh = false
    this.timer = setInterval(() => {
      if (document.hidden || this.element.contains(document.activeElement) || this.element.hasAttribute("busy") || this.element.querySelector("[data-autosave-saving]")) return
      if (this.element.src === window.location.href) this.element.reload()
      else this.element.src = window.location.href
    }, this.intervalValue || 5000)
  }

  invalidate() {
    if (this.element.hasAttribute("busy")) this.discardRefresh = true
  }

  beforeRender(event) {
    // A poll started before the checkbox save may contain outdated values.
    if (this.discardRefresh || this.element.querySelector("[data-autosave-saving]")) {
      event.detail.render = () => {}
      this.discardRefresh = false
    }
  }

  disconnect() { clearInterval(this.timer) }
}
