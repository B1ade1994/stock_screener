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
