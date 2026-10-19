import test from "node:test"
import assert from "node:assert/strict"
import { validLiveCandle, candleGeometry, priceY, rebaseY } from "../../app/javascript/chart_live_candle.js"

const bar = { time: "2026-10-19T00:00:00Z", open: 100, high: 105, low: 98, close: 104, volume: 500 }

test("live candles require actual, consistent OHLCV; missing data never becomes a zero-price candle", () => {
  assert.equal(validLiveCandle(bar), true)
  for (const invalid of [null, {}, { ...bar, low: 101 }, { ...bar, high: 103 },
    { ...bar, close: null }, { ...bar, close: NaN }, { ...bar, volume: -1 }, { ...bar, time: "invalid" }]) {
    assert.equal(validLiveCandle(invalid), false)
  }
})

test("the forming body shrinks, grows and changes direction while wicks retain the range", () => {
  const up = candleGeometry(bar, 90, 110)
  const smaller = candleGeometry({ ...bar, close: 101 }, 90, 110)
  const down = candleGeometry({ ...bar, close: 99 }, 90, 110)
  assert.ok(up.height > smaller.height)
  assert.notEqual(up.color, down.color)
  assert.equal(up.top, down.top)
  assert.equal(up.bottom, down.bottom)
  assert.equal(candleGeometry({ ...bar, close: 100 }, 90, 110).height, 1)
})

test("expanding the scale for new highs preserves prices of candles, EMA and levels", () => {
  for (const price of [90, 98, 100, 105, 110]) {
    assert.ok(Math.abs(rebaseY(priceY(price, 90, 110), 90, 110, 85, 120) - priceY(price, 85, 120)) < 1e-9)
  }
})
