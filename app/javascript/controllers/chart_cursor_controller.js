import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["cursor", "horizontal", "line", "label", "price", "vertical", "dateLabel", "date", "volume"]
  static values = { low: Number, high: Number }

  connect() {
    this.formatter = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 1 })
    this.dates = [...this.element.querySelectorAll(".chart-candle")].map(candle => candle.dataset.date)
    this.volumes = [...this.element.querySelectorAll(".chart-candle")].map(candle => candle.dataset.volume)
    this.volumeBars = [...this.element.querySelectorAll(".chart-volume")]
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
    if (x < 0 || x > 900 || y < 40 || y > 400) return this.hide()

    this.horizontalTarget.setAttribute("visibility", y <= 280 ? "visible" : "hidden")
    const price = this.lowValue + (280 - y) / 240 * (this.highValue - this.lowValue)
    this.priceTarget.textContent = this.formatter.format(price)
    this.horizontalTarget.setAttribute("transform", `translate(0 ${y})`)
    this.cursorTarget.setAttribute("visibility", "visible")

    const width = Math.max(82, this.priceTarget.getComputedTextLength() + 14)
    const left = Math.min(912, 1000 - width)
    this.labelTarget.setAttribute("x", left)
    this.labelTarget.setAttribute("width", width)
    this.priceTarget.setAttribute("x", left + width / 2)
    this.lineTarget.setAttribute("x2", left)

    // Candles have equal spacing; use their dates rather than interpolating calendar days.
    const step = 900 / this.dates.length
    const index = Math.min(Math.floor(x / step), this.dates.length - 1)
    const candleX = (index + 0.5) * step
    this.volumeTarget.textContent = `Объём: ${this.formatter.format(Number(this.volumes[index]))} лот.`
    this.selectedBar?.classList.remove("selected")
    this.selectedBar = this.volumeBars[index]
    this.selectedBar?.classList.add("selected")
    this.verticalTarget.setAttribute("x1", candleX)
    this.verticalTarget.setAttribute("x2", candleX)
    this.dateTarget.textContent = this.dates[index]
    const dateWidth = Math.max(92, this.dateTarget.getComputedTextLength() + 16)
    const dateLeft = Math.max(0, Math.min(candleX - dateWidth / 2, 900 - dateWidth))
    this.dateLabelTarget.setAttribute("x", dateLeft)
    this.dateLabelTarget.setAttribute("width", dateWidth)
    this.dateTarget.setAttribute("x", dateLeft + dateWidth / 2)
  }

  hide() {
    this.horizontalTarget.setAttribute("visibility", "hidden")
    this.selectedBar?.classList.remove("selected")
    this.cursorTarget.setAttribute("visibility", "hidden")
  }
}
