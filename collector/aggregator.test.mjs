import { test } from "node:test";
import assert from "node:assert/strict";
import { Aggregator, quotation } from "./aggregator.mjs";
const minute = Date.parse("2026-09-18T10:00:00Z");
test("quotation preserves nano precision and negative signs", () => {
  assert.equal(quotation({units:"123",nano:456789123}), "123.456789123");
  assert.equal(quotation({units:"0",nano:-500000000}), "-0.500000000");
});
test("minute snapshots are cumulative, keep unknown side, and first minute is partial", () => {
  const a = new Aggregator(["uid"], minute + 1000);
  for (const direction of [1, 2, 0]) a.trade({instrumentUid:"uid", time:new Date(minute+2000).toISOString(), quantity:"10", direction, price:{units:"100",nano:0}}, minute+3000);
  const bar = a.snapshot(minute+3000)[0].bars[0];
  assert.equal(bar.buy,10); assert.equal(bar.sell,10); assert.equal(bar.unknown,10);
  assert.equal(bar.trades,3); assert.equal(bar.complete,false);
  assert.equal(a.snapshot(minute+3000)[0].bars[0].buy,10);
  assert.equal(a.snapshot(minute+70000)[0].bars[0].complete,false);
});
test("late old events do not enter the new session", () => {
  const a = new Aggregator(["uid"], minute+1000);
  a.trade({instrumentUid:"uid",time:new Date(minute).toISOString(),quantity:10,direction:1,price:{units:"100"}},minute+2000);
  assert.equal(a.snapshot(minute+2000)[0].bars[0].trades,0);
});
test("a complete minute excludes a partial startup and current minute", () => {
  const a = new Aggregator(["uid"],minute+1000);
  a.tick(minute+61000);
  const bars = a.snapshot(minute+156000)[0].bars;
  assert.equal(bars.find(b=>Date.parse(b.time)===minute+60000).complete,true);
  assert.equal(bars.find(b=>Date.parse(b.time)===minute+120000).complete,false);
});
