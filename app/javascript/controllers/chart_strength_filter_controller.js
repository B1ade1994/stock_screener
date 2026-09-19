import { Controller } from "@hotwired/stimulus"
import { normalizeStrengthFilter, applyLevelVisibility, strengthCategories } from "chart_level_filter"

export default class extends Controller {
  static targets = ["choice", "all", "menu", "summary"]
  static values = { instrument: Number }

  connect() {
    if (!this.hasMenuTarget) return
    let saved
    try { saved = sessionStorage.getItem(this.storageKey) } catch { /* Storage can be disabled. */ }
    const selected = normalizeStrengthFilter(saved)
    this.choiceTargets.forEach(input => { input.checked = selected.includes(input.value) })
    this.render()
  }

  change() {
    this.render()
    try { sessionStorage.setItem(this.storageKey, this.element.dataset.strengthFilter) } catch { /* Filtering still works. */ }
  }

  toggleAll() {
    this.choiceTargets.forEach(input => { input.checked = this.allTarget.checked })
    this.change()
  }

  render() {
    const selected = this.choiceTargets.filter(input => input.checked).map(input => input.value)
    this.element.dataset.strengthFilter = JSON.stringify(selected)
    this.element.querySelectorAll("[data-chart-level-id]").forEach(applyLevelVisibility)
    this.allTarget.checked = selected.length === strengthCategories.length
    this.allTarget.indeterminate = selected.length > 0 && !this.allTarget.checked
    const labels = { "3": "высокая", "2": "средняя", "1": "низкая", "unrated": "без оценки" }
    const text = this.allTarget.checked ? "все" : selected.length ? selected.map(value => labels[value]).join(", ") : "нет уровней"
    this.summaryTarget.textContent = `Сила: ${text}`
    this.summaryTarget.title = `Сила: ${text}`
  }

  outside(event) {
    if (this.hasMenuTarget && !this.menuTarget.contains(event.target)) this.menuTarget.open = false
  }

  close(event) {
    if (!this.hasMenuTarget || !this.menuTarget.open) return
    this.menuTarget.open = false
    if (event.type === "keydown") this.summaryTarget.focus()
  }

  get storageKey() { return `stock-screener:strength-filter:${this.instrumentValue}` }
}
