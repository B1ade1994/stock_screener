import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "slash", "error"]
  static values = { url: String, id: Number, visible: Boolean }

  async toggle() {
    if (this.buttonTarget.disabled) return
    this.buttonTarget.disabled = true
    this.errorTarget.textContent = ""
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
        },
        body: JSON.stringify({ price_level: { chart_visible: !this.visibleValue } })
      })
      if (!response.ok) throw new Error("Save failed")
      const result = await response.json()
      this.visibleValue = result.chart_visible
      this.buttonTarget.setAttribute("aria-pressed", String(this.visibleValue))
      this.buttonTarget.setAttribute("aria-label", this.visibleValue ? "Скрыть уровень на графике" : "Показать уровень на графике")
      this.buttonTarget.title = this.visibleValue ? "Скрыть на графике" : "Показать на графике"
      this.slashTarget.setAttribute("display", this.visibleValue ? "none" : "inline")
      // Only visibility changes: the chart controller, zoom and page scroll stay intact.
      document.querySelectorAll(`[data-chart-level-id="${this.idValue}"]`).forEach(group => {
        group.setAttribute("display", this.visibleValue ? "inline" : "none")
      })
    } catch {
      this.errorTarget.textContent = "Не удалось сохранить. Попробуйте ещё раз."
    } finally {
      this.buttonTarget.disabled = false
    }
  }
}
