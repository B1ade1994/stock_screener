import { Controller } from "@hotwired/stimulus"
import { ChartViewport } from "chart_viewport"

export default class extends Controller {
  static targets = ["cursor", "horizontal", "line", "label", "price", "vertical", "dateLabel", "date", "volume", "svg", "pricePlot", "volumePlot", "priceTick", "dateStart", "dateEnd"]
  static values = { low: Number, high: Number }

  connect() {
    this.formatter = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 1 })
    this.dates = [...this.element.querySelectorAll(".chart-candle")].map(candle => candle.dataset.date)
    this.volumes = [...this.element.querySelectorAll(".chart-candle")].map(candle => candle.dataset.volume)
    this.volumeBars = [...this.element.querySelectorAll(".chart-volume")]
    this.viewport = new ChartViewport(this.dates.length)
    this.onWheel = event => this.wheel(event)
    this.svgTarget.addEventListener("wheel", this.onWheel, { passive: false })
    this.render()
    this.hide()
  }

  disconnect() {
    this.svgTarget.removeEventListener("wheel", this.onWheel)
    this.finishDrag()
  }

  point(event) {
    const matrix = this.svgTarget.getScreenCTM()
    if (!matrix) return null
    const point = this.svgTarget.createSVGPoint()
    point.x = event.clientX
    point.y = event.clientY
    return point.matrixTransform(matrix.inverse())
  }

  inside(point) { return point && point.x >= 0 && point.x <= 900 && point.y >= 40 && point.y <= 400 }

  wheel(event) {
    const point = this.point(event)
    if (!this.inside(point) || this.drag) return
    event.preventDefault()
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 360 : 1
    const delta = Math.max(-300, Math.min(300, event.deltaY * unit))
    this.viewport.zoom(Math.exp(-delta * 0.002), point.x, Math.min(point.y, 280), point.y <= 280)
    this.render()
    this.move(event)
  }

  startDrag(event) {
    if (!event.isPrimary || event.button !== 0) return
    const point = this.point(event)
    if (!this.inside(point)) return
    event.preventDefault()
    this.drag = { pointerId: event.pointerId, x: point.x, y: point.y, vertical: point.y <= 280 }
    this.svgTarget.setPointerCapture(event.pointerId)
    this.svgTarget.classList.add("is-panning")
    this.hide()
  }

  finishDrag(event) {
    if (!this.drag || (event && event.pointerId !== this.drag.pointerId)) return
    const id = this.drag.pointerId
    this.drag = null
    if (this.svgTarget.hasPointerCapture(id)) this.svgTarget.releasePointerCapture(id)
    this.svgTarget.classList.remove("is-panning")
    this.hide()
  }

  zoomIn() { this.viewport.zoom(1.4); this.render(); this.hide() }
  zoomOut() { this.viewport.zoom(1 / 1.4); this.render(); this.hide() }
  reset() { this.finishDrag(); this.viewport.reset(); this.render(); this.hide() }

  key(event) {
    if (event.ctrlKey || event.metaKey || event.altKey) return
    const actions = {
      "+": () => this.zoomIn(), "=": () => this.zoomIn(), "-": () => this.zoomOut(),
      "Home": () => this.reset(),
      "ArrowLeft": () => this.viewport.pan(90), "ArrowRight": () => this.viewport.pan(-90),
      "ArrowUp": () => this.viewport.pan(0, 24), "ArrowDown": () => this.viewport.pan(0, -24)
    }
    if (!actions[event.key]) return
    event.preventDefault()
    actions[event.key]()
    this.render()
    this.hide()
  }

  render() {
    const view = this.viewport
    this.pricePlotTarget.setAttribute("transform", view.priceTransform)
    this.volumePlotTarget.setAttribute("transform", view.volumeTransform)
    this.priceTickTargets.forEach(tick => {
      const sourceY = view.sourceY(Number(tick.dataset.y))
      const price = this.lowValue + (280 - sourceY) / 240 * (this.highValue - this.lowValue)
      tick.textContent = this.formatter.format(price)
    })
    const first = view.candleAt(0, this.dates.length)
    const last = view.candleAt(900 - 1e-7, this.dates.length)
    this.dateStartTarget.textContent = this.dates[first]
    this.dateEndTarget.textContent = this.dates[last]
  }

  move(event) {
    const point = this.point(event)
    if (!point) return this.hide()
    const { x, y } = point
    if (this.drag) {
      if (event.pointerId !== this.drag.pointerId) return
      this.viewport.pan(x - this.drag.x, this.drag.vertical ? y - this.drag.y : 0)
      this.drag.x = x
      this.drag.y = y
      this.render()
      return
    }
    if (!this.inside(point)) return this.hide()

    this.horizontalTarget.setAttribute("visibility", y <= 280 ? "visible" : "hidden")
    const price = this.lowValue + (280 - this.viewport.sourceY(y)) / 240 * (this.highValue - this.lowValue)
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
    const index = this.viewport.candleAt(x, this.dates.length)
    const candleX = Math.max(0, Math.min(900, this.viewport.screenX((index + 0.5) * step)))
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
