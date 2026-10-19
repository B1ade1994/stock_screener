export function validLiveCandle(bar) {
  if (!bar || !Number.isFinite(Date.parse(bar.time))) return false
  const values = [bar.open, bar.high, bar.low, bar.close]
  return values.every(value => typeof value === "number" && Number.isFinite(value) && value > 0) &&
    bar.high >= Math.max(...values) && bar.low <= Math.min(...values) &&
    Number.isSafeInteger(bar.volume) && bar.volume >= 0
}

export const priceY = (price, low, high) => 280 - (price - low) / (high - low) * 240

export function candleGeometry(bar, low, high) {
  const openY = priceY(bar.open, low, high), closeY = priceY(bar.close, low, high)
  return { top: priceY(bar.high, low, high), bottom: priceY(bar.low, low, high),
    y: Math.min(openY, closeY), height: Math.max(Math.abs(openY - closeY), 1),
    color: bar.close >= bar.open ? "#168779" : "#cb6b64" }
}

// Change the underlying SVG scale while preserving each historical price.
export function rebaseY(y, oldLow, oldHigh, low, high) {
  return priceY(oldLow + (280 - y) / 240 * (oldHigh - oldLow), low, high)
}
