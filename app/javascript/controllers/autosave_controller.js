import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.checkbox = this.element.querySelector('input[type="checkbox"]')
    this.savedChecked = this.checkbox.checked
    this.row = this.element.closest("tr")
  }

  submit() {
    this.element.requestSubmit()
  }

  start() {
    // Turbo has already captured the form data, so disabling inputs is safe here.
    this.row.setAttribute("data-autosave-saving", "")
    this.row.querySelectorAll('input[type="checkbox"]').forEach(input => { input.disabled = true })
    this.row.querySelector("[data-autosave-feedback]").textContent = ""
  }

  finish(event) {
    this.row.removeAttribute("data-autosave-saving")
    this.row.querySelectorAll('input[type="checkbox"]').forEach(input => { input.disabled = false })
    // A server response replaces the row with persisted values. Network errors leave it in place.
    if (!event.detail.success && this.element.isConnected) {
      this.checkbox.checked = this.savedChecked
      this.row.querySelector("[data-autosave-feedback]").textContent = "Не удалось сохранить. Проверьте соединение и попробуйте ещё раз."
    }
  }
}
