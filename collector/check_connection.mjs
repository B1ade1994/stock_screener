const token = process.env.TINVEST_TOKEN;
const response = await fetch('https://invest-public-api.tbank.ru/rest/tinkoff.public.invest.api.contract.v1.InstrumentsService/FindInstrument', {method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({query:'SBER'})});
if (!response.ok) throw new Error(`Search HTTP ${response.status}`);
const {instruments} = await response.json();
const instrument = instruments.find(i=>i.ticker==='SBER' && i.classCode==='TQBR');
if (!instrument) throw new Error('SBER not found');
const ws = new WebSocket('wss://invest-public-api.tbank.ru/ws/tinkoff.public.invest.api.contract.v1.MarketDataStreamService/MarketDataStream',['json',token]);
const timer = setTimeout(()=>{ console.error('Stream check timed out'); process.exit(1) },20000);
ws.onopen=()=>{ console.log("WebSocket opened"); ws.send(JSON.stringify({subscribeTradesRequest:{subscriptionAction:'SUBSCRIPTION_ACTION_SUBSCRIBE',instruments:[{instrumentId:instrument.uid}],tradeSource:'TRADE_SOURCE_EXCHANGE'}})); }; 
ws.onmessage=e=>{
 const p=JSON.parse(e.data);
 if(p.subscribeTradesResponse){ const statuses=p.subscribeTradesResponse.tradeSubscriptions.map(s=>s.subscriptionStatus); console.log('Stream subscription statuses:', statuses); if (!statuses.every(s=>s==='SUBSCRIPTION_STATUS_SUCCESS'||s===1)) process.exit(1); ws.send(JSON.stringify({ping:{time:new Date().toISOString()}})) }
 if(p.ping){ console.log('Stream heartbeat received'); clearTimeout(timer); ws.close(); process.exit(0) }
 if(p.error||p.code){ console.error('Stream rejected request');process.exit(1) }
};
ws.onerror=()=>{console.error('Stream connection failed');process.exit(1)};
