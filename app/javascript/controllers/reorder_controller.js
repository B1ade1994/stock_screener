import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "status"]

  start(event) {
    if (event.button !== 0 || event.isPrimary === false) return
    if (!this.begin(event.currentTarget.closest("tr"))) return
    event.preventDefault()
    this.pointerId = event.pointerId
    this.startY = this.pointerY = event.clientY
    this.element.setPointerCapture(event.pointerId)
  }

  begin(row) {
    if (this.row || this.element.querySelector("[data-autosave-saving]")) return false
    this.row = row
    this.originalRows = [...this.listTarget.children]
    this.controls = [...this.element.querySelectorAll('input[type="checkbox"]:not(:disabled)')]
    this.controls.forEach(input => { input.disabled = true })
    this.listTarget.setAttribute("data-autosave-saving", "")
    this.element.classList.add("reordering")
    row.classList.add("dragging-row")
    row.querySelector("[data-autosave-feedback]").textContent = ""
    this.dispatch("start")
    return true
  }

  drag(event) {
    if (this.pointerId !== event.pointerId) return
    this.pointerY = event.clientY
    if (!this.dragging && Math.abs(this.pointerY - this.startY) < 4) return
    event.preventDefault()
    if (!this.dragging) {
      this.dragging = true
      this.scrollFrame = requestAnimationFrame(() => this.autoScroll())
    }
    this.moveAtPointer()
  }

  moveAtPointer() {
    const next = [...this.listTarget.children].find(row => {
      if (row === this.row) return false
      const bounds = row.getBoundingClientRect()
      return this.pointerY < bounds.top + bounds.height / 2
    })
    this.listTarget.insertBefore(this.row, next || null)
  }

  autoScroll() {
    if (!this.dragging) return
    const edge = 70
    const speed = this.pointerY < edge ? -12 : this.pointerY > window.innerHeight - edge ? 12 : 0
    if (speed) {
      window.scrollBy(0, speed)
      this.moveAtPointer()
    }
    this.scrollFrame = requestAnimationFrame(() => this.autoScroll())
  }

  drop(event) {
    if (this.pointerId !== event.pointerId) return
    this.releasePointer()
    this.save()
  }

  cancel() {
    if (this.pointerId === undefined) return
    this.releasePointer()
    this.restore()
    this.statusTarget.textContent = "Перемещение отменено"
    this.finish()
  }

  key(event) {
    if (!["ArrowUp", "ArrowDown"].includes(event.key)) return
    event.preventDefault()
    const row = event.currentTarget.closest("tr")
    const target = event.key === "ArrowUp" ? row.previousElementSibling : row.nextElementSibling
    if (!target || !this.begin(row)) return
    this.listTarget.insertBefore(row, event.key === "ArrowUp" ? target : target.nextElementSibling)
    event.currentTarget.focus({ preventScroll: true })
    this.save()
  }

  async save() {
    if (this.originalRows.every((row, index) => row === this.listTarget.children[index])) {
      this.finish()
      return
    }
    const next = this.row.nextElementSibling
    const target = next || this.row.previousElementSibling
    this.statusTarget.textContent = "Сохраняем порядок"
    try {
      const response = await fetch(this.row.dataset.moveUrl, {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
        },
        body: JSON.stringify({ target_id: target.dataset.instrumentId, placement: next ? "before" : "after" }),
        signal: AbortSignal.timeout(15000)
      })
      if (!response.ok) throw new Error("Save failed")
      this.statusTarget.textContent = "Порядок сохранён"
    } catch {
      this.restore()
      this.statusTarget.textContent = "Не удалось сохранить порядок"
      this.row.querySelector("[data-autosave-feedback]").textContent = "Не удалось сохранить порядок. Попробуйте ещё раз."
    } finally {
      this.finish()
    }
  }

  restore() {
    this.originalRows.forEach(row => this.listTarget.appendChild(row))
  }

  releasePointer() {
    this.dragging = false
    cancelAnimationFrame(this.scrollFrame)
    if (this.pointerId !== undefined && this.element.hasPointerCapture(this.pointerId)) {
      this.element.releasePointerCapture(this.pointerId)
    }
    this.pointerId = undefined
  }

  finish() {
    this.row?.classList.remove("dragging-row")
    this.element.classList.remove("reordering")
    this.listTarget.removeAttribute("data-autosave-saving")
    this.controls?.forEach(input => { input.disabled = false })
    this.row = null
  }

  disconnect() {
    this.releasePointer()
  }
}
