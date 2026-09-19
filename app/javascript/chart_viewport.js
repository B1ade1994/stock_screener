const clamp = (value, min, max) => Math.max(min, Math.min(value, max))

// Coordinates in the original server-rendered SVG. Axes and cursor stay untransformed.
export class ChartViewport {
  constructor(count) {
    this.count = count
    this.maxXZoom = Math.max(1, Math.min(40, count / 5))
    this.reset()
  }

  reset() { this.left = 0; this.top = 40; this.width = 900; this.height = 240 }
  showFrom(index) {
    this.reset()
    if (this.count <= 0) return
    const start = clamp(index, 0, this.count - 1)
    this.width = clamp(900 * (this.count - start) / this.count, 900 / this.maxXZoom, 900)
    this.left = 900 - this.width
  }

  fitCandles(bounds) {
    if (!bounds.length) return
    const first = this.candleAt(0, bounds.length)
    const last = this.candleAt(900 - 1e-7, bounds.length)
    const visible = bounds.slice(first, last + 1)
    const top = Math.min(...visible.map(bar => bar.top))
    const bottom = Math.max(...visible.map(bar => bar.bottom))
    if (!Number.isFinite(top) || !Number.isFinite(bottom)) return
    const padding = (bottom - top) * 0.06
    this.height = clamp(bottom - top + padding * 2, 12, 240)
    this.top = clamp((top + bottom - this.height) / 2, 40, 280 - this.height)
  }

  get scaleX() { return 900 / this.width }
  get scaleY() { return 240 / this.height }
  get full() { return this.width === 900 && this.height === 240 }
  get maximum() { return this.scaleX >= this.maxXZoom - 1e-8 && this.scaleY >= 20 - 1e-8 }
  sourceX(x) { return this.left + x / this.scaleX }
  sourceY(y) { return this.top + (y - 40) / this.scaleY }
  screenX(x) { return (x - this.left) * this.scaleX }
  screenY(y) { return 40 + (y - this.top) * this.scaleY }

  zoom(factor, x = 450, y = 160, vertical = true) {
    const anchorX = this.sourceX(x), anchorY = this.sourceY(y)
    this.width = clamp(this.width / factor, 900 / this.maxXZoom, 900)
    if (vertical) this.height = clamp(this.height / factor, 12, 240)
    this.left = clamp(anchorX - x / this.scaleX, 0, 900 - this.width)
    this.top = clamp(anchorY - (y - 40) / this.scaleY, 40, 280 - this.height)
  }

  pan(dx, dy = 0) {
    this.left = clamp(this.left - dx / this.scaleX, 0, 900 - this.width)
    this.top = clamp(this.top - dy / this.scaleY, 40, 280 - this.height)
  }

  candleAt(x, count) {
    return clamp(Math.floor(this.sourceX(x) / 900 * count), 0, count - 1)
  }

  priceMarker(price, low, high) {
    if (price == null || price === "" || !Number.isFinite(Number(price)) || Number(price) <= 0 || high <= low) return null
    const y = this.screenY(280 - (Number(price) - low) / (high - low) * 240)
    return { y: clamp(y, 40, 280), inRange: y >= 40 && y <= 280, direction: y < 40 ? "↑" : y > 280 ? "↓" : "" }
  }

  get priceTransform() { return `translate(${-this.left * this.scaleX} ${40 - this.top * this.scaleY}) scale(${this.scaleX} ${this.scaleY})` }
  get volumeTransform() { return `translate(${-this.left * this.scaleX} 0) scale(${this.scaleX} 1)` }
}
