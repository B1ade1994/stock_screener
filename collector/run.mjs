import { Aggregator } from "./aggregator.mjs";
const base = process.env.SCREENER_URL || "http://localhost:3002";
const token = process.env.TINVEST_TOKEN;
const internalToken = process.env.INTERNAL_API_TOKEN;
if (!token || !internalToken) throw new Error("TINVEST_TOKEN and INTERNAL_API_TOKEN are required");
const endpoint = "wss://invest-public-api.tbank.ru/ws/tinkoff.public.invest.api.contract.v1.MarketDataStreamService/MarketDataStream";
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function api(path, body) {
  const response = await fetch(`${base}/internal/${path}`, { method: body ? "POST" : "GET", headers: { Authorization: `Bearer ${internalToken}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(8000) });
  if (!response.ok) throw new Error(`Rails HTTP ${response.status}`);
  return response.status === 204 ? null : response.json();
}
let socket, aggregator, wanted = "", connected = false, lastMessage = 0, lastPing = 0, lastDelivery = Date.now(), nextRetry = 0, retry = 1000, message = "Ожидаем список инструментов";
function disconnect(reason) {
  connected = false; message = reason; aggregator = null;
  const old = socket; socket = null;
  if (old) old.close();
  nextRetry = Date.now() + retry; retry = Math.min(retry * 2, 30000);
}
function connect(uids) {
  lastMessage = Date.now(); message = "Подключение к Т-Инвестициям";
  const current = new WebSocket(endpoint, ["json", token]); socket = current;
  current.onopen = () => current.send(JSON.stringify({ subscribeTradesRequest: { subscriptionAction: "SUBSCRIPTION_ACTION_SUBSCRIBE", instruments: uids.map(instrumentId => ({ instrumentId })), tradeSource: "TRADE_SOURCE_EXCHANGE" } }));
  current.onmessage = event => {
    if (socket !== current) return;
    lastMessage = Date.now();
    try {
      const payload = JSON.parse(event.data);
      if (payload.error || payload.code) { disconnect("API отклонил запрос; проверьте токен и доступ к инструментам"); return; }
      const ack = payload.subscribeTradesResponse;
      if (ack) {
        const subscriptions = ack.tradeSubscriptions || [];
        const ok = subscriptions.length === uids.length && subscriptions.every(s => s.subscriptionStatus === "SUBSCRIPTION_STATUS_SUCCESS" || s.subscriptionStatus === 1);
        if (!ok) { disconnect("Подписка отклонена API; проверьте доступность инструментов"); return; }
        current.send(JSON.stringify({ ping: { time: new Date().toISOString() } }));
        lastPing = Date.now();
        aggregator = new Aggregator(uids); connected = true; retry = 1000; message = "Поток биржевых сделок подключён";
      }
      if (payload.trade && connected) aggregator.trade(payload.trade);
    } catch { disconnect("Некорректное сообщение потока"); }
  };
  current.onerror = () => { if (socket === current) disconnect("Ошибка соединения с Т-Инвестициями"); };
  current.onclose = () => { if (socket === current) disconnect("Соединение закрыто; переподключаемся"); };
}
let nextWatchlist = 0;
while (true) {
  try {
    if (Date.now() >= nextWatchlist) {
      const { instruments } = await api("watchlist"); const key = JSON.stringify(instruments);
      if (key !== wanted) { disconnect("Список наблюдения изменён"); wanted = key; nextRetry = 0; }
      if (!instruments.length) message = "Добавьте инструмент для наблюдения";
      if (instruments.length && !socket && Date.now() >= nextRetry) connect(instruments);
      nextWatchlist = Date.now() + 10000;
    }
    if (Date.now() - lastDelivery > 15000) disconnect("Пауза доставки данных; прогрев начнётся заново");
    if (connected && socket && Date.now() - lastPing > 10000) {
      socket.send(JSON.stringify({ ping: { time: new Date().toISOString() } }));
      lastPing = Date.now();
    }
    if (socket && Date.now() - lastMessage > 30000) disconnect("Поток не отвечает; переподключаемся");
    await api("ingest", { status: connected ? "connected" : wanted === "[]" ? "idle" : "reconnecting", message, instruments: connected && aggregator ? aggregator.snapshot() : [] });
    lastDelivery = Date.now();
  } catch {
    // A delivery gap starts a new baseline; never silently treat missing volume as complete.
    disconnect("Rails недоступен; сбор возобновится с новым периодом прогрева");
    console.error("Collector delivery failed; retrying (credentials omitted)");
  }
  await sleep(3000);
}
