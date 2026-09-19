import { Controller } from "@hotwired/stimulus"
import { ChartViewport } from "chart_viewport"

export default class extends Controller {
  static targets = ["cursor", "horizontal", "line", "label", "price", "vertical", "dateLabel", "date", "volume", "svg", "pricePlot", "volumePlot", "priceTick", "dateStart", "dateEnd", "currentPrice", "currentPriceLine", "currentPriceLabel", "currentPriceText", "currentPriceTitle"]
  static values = { low: Number, high: Number, startIndex: Number, quoteUrl: String, lastPrice: Number, lastTradeAt: String }

  connect() {
    this.quote = { price: this.hasLastPriceValue ? this.lastPriceValue : null, traded_at: this.lastTradeAtValue }
    this.quoteAbort = new AbortController()
    this.formatter = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 1 })
    this.dates = [...this.element.querySelectorAll(".chart-candle")].map(candle => candle.dataset.date)
    this.volumes = [...this.element.querySelectorAll(".chart-candle")].map(candle => candle.dataset.volume)
    this.volumeBars = [...this.element.querySelectorAll(".chart-volume")]
    this.viewport = new ChartViewport(this.dates.length)
    this.onWheel = event => this.wheel(event)
    this.svgTarget.addEventListener("wheel", this.onWheel, { passive: false })
    this.restoreInitial()
    if (this.hasQuoteUrlValue) this.refreshQuote(this.quoteAbort.signal)
  }

  restoreInitial() {
    this.finishDrag()
    this.viewport.showFrom(this.startIndexValue)
    if (this.svgTarget.dataset.timeframe === "day") {
      const bounds = [...this.element.querySelectorAll(".chart-candle > line")].map(wick => ({
        top: Number(wick.getAttribute("y1")), bottom: Number(wick.getAttribute("y2"))
      }))
      this.viewport.fitCandles(bounds)
    }
    this.render()
    this.hide()
  }

  disconnect() {
    this.quoteAbort.abort()
    clearTimeout(this.quoteTimer)
    this.svgTarget.removeEventListener("wheel", this.onWheel)
    this.finishDrag()
  }

  async refreshQuote(signal) {
    try {
      if (!document.hidden) {
        const response = await fetch(this.quoteUrlValue, { headers: { Accept: "application/json" }, cache: "no-store", signal })
        if (!response.ok) throw new Error("Quote unavailable")
        const quote = await response.json()
        if (!signal.aborted) this.quote = quote
      }
    } catch (error) {
      // Keep the last received quote; its trade timestamp still shows its age.
    } finally {
      if (!signal.aborted) {
        this.renderCurrentPrice()
        this.quoteTimer = setTimeout(() => this.refreshQuote(signal), 5000)
      }
    }
  }

  renderCurrentPrice() {
    const marker = this.viewport.priceMarker(this.quote.price, this.lowValue, this.highValue)
    this.currentPriceTarget.setAttribute("display", marker ? "inline" : "none")
    if (!marker) return
    const tradedAt = Date.parse(this.quote.traded_at)
    const stale = !Number.isFinite(tradedAt) || Date.now() - tradedAt > 120000
    const color = stale ? "#b7791f" : "#168779"
    this.currentPriceTextTarget.textContent = `${marker.direction ? marker.direction + " " : ""}${this.formatter.format(Number(this.quote.price))}`
    const width = Math.max(82, this.currentPriceTextTarget.getComputedTextLength() + 14)
    const left = Math.min(912, 1000 - width)
    this.currentPriceTarget.setAttribute("transform", `translate(0 ${marker.y})`)
    this.currentPriceLineTarget.setAttribute("visibility", marker.inRange ? "visible" : "hidden")
    this.currentPriceLineTarget.setAttribute("stroke", color)
    this.currentPriceLineTarget.setAttribute("x2", left)
    this.currentPriceLabelTarget.setAttribute("fill", color)
    this.currentPriceLabelTarget.setAttribute("x", left)
    this.currentPriceLabelTarget.setAttribute("width", width)
    this.currentPriceTextTarget.setAttribute("x", left + width / 2)
    const time = Number.isFinite(tradedAt) ? new Date(tradedAt).toLocaleString("ru-RU", { timeZone: "Europe/Moscow" }) + " МСК" : "время неизвестно"
    const description = `Последняя сделка: ${this.formatter.format(Number(this.quote.price))} · ${time}${stale ? " · Нет свежих сделок" : ""}${marker.inRange ? "" : " · За пределами видимой шкалы"}`
    this.currentPriceTitleTarget.textContent = description
    this.currentPriceTarget.setAttribute("aria-label", description)
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

  prepareForCache() {
    // Frame navigation can cache the page after the new chart has connected.
    // Hide transient UI without undoing its initial two-month viewport.
    this.finishDrag()
    this.hide()
  }

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
    // Horizontal levels continue through the empty space after the latest candle.
    this.pricePlotTarget.querySelectorAll(".chart-level").forEach(line => {
      line.setAttribute("x1", view.sourceX(0))
      line.setAttribute("x2", view.sourceX(900))
    })
    this.pricePlotTarget.querySelectorAll(".chart-zone").forEach(zone => {
      zone.setAttribute("x", view.sourceX(0))
      zone.setAttribute("width", view.width)
    })
    const visible = view.visibleCandles
    this.dateStartTarget.textContent = visible ? this.dates[visible.first] : ""
    this.dateEndTarget.textContent = visible ? this.dates[visible.last] : ""
    if (visible) {
      const endX = Math.min(900, view.screenX((visible.last + 1) / this.dates.length * 900))
      this.dateEndTarget.setAttribute("x", endX)
      if (endX < 160) this.dateStartTarget.textContent = ""
    }
    this.renderCurrentPrice()
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
    const index = this.viewport.candleUnder(x)
    const hasCandle = index !== null
    ;[this.verticalTarget, this.dateLabelTarget, this.dateTarget].forEach(target => {
      target.setAttribute("display", hasCandle ? "inline" : "none")
    })
    this.selectedBar?.classList.remove("selected")
    if (!hasCandle) {
      this.selectedBar = null
      this.volumeTarget.textContent = ""
      return
    }
    const candleX = Math.max(0, Math.min(900, this.viewport.screenX((index + 0.5) * step)))
    this.volumeTarget.textContent = this.volumes[index] === "" ? "Объём SP500F недоступен · история SPY" : `Объём: ${this.formatter.format(Number(this.volumes[index]))} лот.`
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
