import { randomUUID } from "node:crypto";
export function quotation(q) {
  const n = BigInt(q.units || 0) * 1000000000n + BigInt(q.nano || 0);
  const abs = n < 0 ? -n : n;
  return `${n < 0 ? "-" : ""}${abs / 1000000000n}.${String(abs % 1000000000n).padStart(9, "0")}`;
}
export class Aggregator {
  constructor(uids, now = Date.now()) {
    this.session = randomUUID(); this.started = now;
    this.items = new Map(uids.map(uid => [uid, { uid, bars: new Map() }]));
  }
  tick(now = Date.now()) {
    const minute = Math.floor(now / 60000) * 60000;
    for (const item of this.items.values()) {
      for (const time of [minute - 60000, minute]) {
        if (time < Math.floor(this.started / 60000) * 60000 || item.bars.has(time)) continue;
        item.bars.set(time, { time: new Date(time).toISOString(), session: this.session, buy: 0, sell: 0, unknown: 0, trades: 0 });
      }
      for (const time of item.bars.keys()) if (time < minute - 120000) item.bars.delete(time);
    }
  }
  trade(trade, now = Date.now()) {
    const item = this.items.get(trade.instrumentUid);
    if (!item) return;
    const time = Date.parse(trade.time), quantity = Number(trade.quantity);
    if (!Number.isFinite(time) || time > now + 5000 || time < this.started || now - time > 30000 || !Number.isSafeInteger(quantity) || quantity <= 0) return;
    this.tick(now);
    const bar = item.bars.get(Math.floor(time / 60000) * 60000);
    if (!bar) return;
    const field = trade.direction === "TRADE_DIRECTION_BUY" || trade.direction === 1 ? "buy" : trade.direction === "TRADE_DIRECTION_SELL" || trade.direction === 2 ? "sell" : "unknown";
    bar[field] += quantity; bar.trades++;
    const price = quotation(trade.price);
    if (!bar.open_time || time < Date.parse(bar.open_time)) { bar.open_price = price; bar.open_time = trade.time; }
    if (!bar.close_time || time >= Date.parse(bar.close_time)) { bar.close_price = price; bar.close_time = trade.time; }
    if (!item.trade_time || time >= Date.parse(item.trade_time)) { item.price = quotation(trade.price); item.trade_time = trade.time; }
  }
  snapshot(now = Date.now()) {
    this.tick(now);
    return [...this.items.values()].map(item => ({ ...item, bars: [...item.bars.entries()].map(([time, bar]) => ({ ...bar, complete: time >= this.started && now >= time + 95000 })) }));
  }
}
