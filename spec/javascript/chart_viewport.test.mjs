import test from "node:test"
import assert from "node:assert/strict"
import { ChartViewport } from "../../app/javascript/chart_viewport.js"
const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-7, `${a} != ${b}`)

test("zoom keeps the pointed candle and price anchored", () => {
  const view = new ChartViewport(300)
  const x = view.sourceX(730), y = view.sourceY(215)
  const candle = view.candleAt(730, 300)
  view.zoom(3, 730, 215)
  close(view.sourceX(730), x)
  close(view.sourceY(215), y)
  assert.equal(view.candleAt(730, 300), candle)
  assert.equal(view.full, false)
})

test("pan follows the pointer with matching screen and data coordinates", () => {
  const view = new ChartViewport(300)
  view.zoom(3)
  const x = view.sourceX(450), y = view.sourceY(160)
  view.pan(90, 24)
  close(view.screenX(x), 540)
  close(view.screenY(y), 184)
  close(view.sourceX(view.screenX(x)), x)
  close(view.sourceY(view.screenY(y)), y)
})

test("panning is bounded by loaded history and cannot lose the plot", () => {
  const view = new ChartViewport(100)
  view.zoom(4)
  view.pan(100000, 100000)
  close(view.sourceX(0), 0)
  close(view.sourceY(40), 40)
  view.pan(-100000, -100000)
  close(view.sourceX(900), 900)
  close(view.sourceY(280), 280)
  assert.equal(view.candleAt(900, 100), 99)
})

test("volume-area zoom changes time only", () => {
  const view = new ChartViewport(100)
  view.zoom(2, 600, 280, false)
  close(view.sourceX(600), 600)
  close(view.sourceY(40), 40)
  close(view.sourceY(280), 280)
  close(view.width, 450)
})

test("extreme zoom is bounded and reset restores the whole history", () => {
  const view = new ChartViewport(100)
  view.zoom(1e9)
  close(view.width, 45) // At least five bars remain in the time window.
  close(view.height, 12)
  assert.equal(view.maximum, true)
  view.reset()
  assert.equal(view.full, true)
  assert.equal(view.candleAt(0, 100), 0)
  assert.equal(view.candleAt(900, 100), 99)
  close(view.sourceY(160), 160)
  view.zoom(0.001)
  assert.equal(view.full, true)
})

test("short series keeps valid candle lookup and supports price zoom", () => {
  const view = new ChartViewport(1)
  view.zoom(10)
  close(view.width, 900)
  assert.equal(view.candleAt(0, 1), 0)
  assert.equal(view.candleAt(900, 1), 0)
  assert.ok(view.height < 240)
})


test("initial time window ends at the latest candle without changing price scale", () => {
  const view = new ChartViewport(300)
  view.showFrom(210)
  assert.equal(view.candleAt(0, 300), 210)
  assert.equal(view.candleAt(900 - 1e-7, 300), 299)
  close(view.width, 270)
  close(view.height, 240)
  view.pan(900)
  assert.ok(view.candleAt(0, 300) < 210)
  view.reset()
  assert.equal(view.full, true)
  assert.equal(view.candleAt(0, 300), 0)
})

test("initial window supports short and empty histories", () => {
  for (const count of [0, 1, 3, 100]) {
    const view = new ChartViewport(count)
    view.showFrom(0)
    assert.equal(view.full, true)
  }
  const view = new ChartViewport(100)
  view.showFrom(99)
  close(view.width, 45)
  close(view.sourceX(900), 900)
})


test("daily opening fits visible candle wicks with padding and ignores old extremes", () => {
  const bounds = Array.from({ length: 100 }, (_, i) => i < 80
    ? { top: 40, bottom: 280 } : { top: 190, bottom: 230 })
  const view = new ChartViewport(bounds.length)
  view.showFrom(80)
  const width = view.width, left = view.left
  view.fitCandles(bounds)
  close(view.width, width)
  close(view.left, left)
  close(view.height, 44.8)
  assert.ok(view.screenY(190) > 40)
  assert.ok(view.screenY(230) < 280)
  assert.ok(view.screenY(230) - view.screenY(190) > 200)
  close(view.sourceY(view.screenY(210)), 210)
  view.reset()
  assert.equal(view.full, true)
})

test("fitting a flat or short series stays finite and within the price bounds", () => {
  for (const y of [40, 160, 280]) {
    const view = new ChartViewport(1)
    view.fitCandles([{ top: y, bottom: y }])
    assert.ok(Number.isFinite(view.scaleY))
    assert.ok(view.sourceY(40) >= 40)
    assert.ok(view.sourceY(280) <= 280)
    assert.ok(view.screenY(y) >= 40 && view.screenY(y) <= 280)
  }
  const empty = new ChartViewport(0)
  empty.fitCandles([])
  assert.equal(empty.full, true)
})


test("last trade marker tracks its price through zoom and pan without changing the viewport", () => {
  const view = new ChartViewport(100)
  view.showFrom(70)
  view.fitCandles(Array.from({ length: 100 }, () => ({ top: 150, bottom: 230 })))
  for (const change of [() => {}, () => view.zoom(1.2, 450, 160), () => view.pan(25, 10)]) {
    change()
    const before = [view.left, view.top, view.width, view.height]
    const marker = view.priceMarker("175.25", 100, 300)
    assert.equal(marker.inRange, true)
    close(100 + (280 - view.sourceY(marker.y)) / 240 * 200, 175.25)
    assert.deepEqual([view.left, view.top, view.width, view.height], before)
  }
})

test("off-screen current price is indicated at the correct edge, never by a false price line", () => {
  const view = new ChartViewport(100)
  assert.deepEqual(view.priceMarker(350, 100, 300), { y: 40, inRange: false, direction: "↑" })
  assert.deepEqual(view.priceMarker(50, 100, 300), { y: 280, inRange: false, direction: "↓" })
  view.zoom(2)
  assert.equal(view.priceMarker(290, 100, 300).inRange, false)
  assert.equal(view.priceMarker(200, 100, 300).inRange, true)
})

test("missing or invalid quotes do not become zero-price markers", () => {
  const view = new ChartViewport(10)
  for (const price of [null, undefined, "", 0, -1, "invalid", Infinity]) {
    assert.equal(view.priceMarker(price, 100, 300), null)
  }
})
