import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["cursor", "line", "label", "price"]
  static values = { low: Number, high: Number }

  connect() {
    this.formatter = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 4 })
    this.hide()
  }

  move(event) {
    // Convert viewport coordinates to SVG coordinates, including scaling and scroll.
    const matrix = this.element.getScreenCTM()
    if (!matrix) return this.hide()
    const point = this.element.createSVGPoint()
    point.x = event.clientX
    point.y = event.clientY
    const { x, y } = point.matrixTransform(matrix.inverse())
    if (x < 0 || x > 900 || y < 40 || y > 280) return this.hide()

    const price = this.lowValue + (280 - y) / 240 * (this.highValue - this.lowValue)
    this.priceTarget.textContent = this.formatter.format(price)
    this.cursorTarget.setAttribute("transform", `translate(0 ${y})`)
    this.cursorTarget.setAttribute("visibility", "visible")

    const width = Math.max(82, this.priceTarget.getComputedTextLength() + 14)
    const left = Math.min(912, 1000 - width)
    this.labelTarget.setAttribute("x", left)
    this.labelTarget.setAttribute("width", width)
    this.priceTarget.setAttribute("x", left + width / 2)
    this.lineTarget.setAttribute("x2", left)
  }

  hide() {
    this.cursorTarget.setAttribute("visibility", "hidden")
  }
}
