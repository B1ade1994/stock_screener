require "net/http"
require "json"

module TInvest
  class Client
    ROOT = "https://invest-public-api.tbank.ru/rest/tinkoff.public.invest.api.contract.v1."
    ALLOWED = %w[InstrumentsService/FindInstrument InstrumentsService/GetInstrumentBy InstrumentsService/FutureBy MarketDataService/GetCandles].freeze
    def call(method, body)
      raise Error, "Метод API не разрешён" unless ALLOWED.include?(method)
      token = ENV["TINVEST_TOKEN"].to_s
      raise Error, "Не задан TINVEST_TOKEN" if token.empty?
      uri = URI(ROOT + method)
      request = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json")
      request.body = JSON.generate(body)
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      store.add_file(Rails.root.join("config/certs/russiantrustedca.pem").to_s)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, cert_store: store, open_timeout: 10, read_timeout: 25) { |http| http.request(request) }
      raise Error, "Т-Инвестиции: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, JSON::ParserError => e
      raise Error, "Соединение с API недоступно (#{e.class.name})"
    end
    def search(query)
      instruments = call("InstrumentsService/FindInstrument", { query: query }).fetch("instruments", []).select do |instrument|
        instrument["instrumentType"] == "futures" ||
          (instrument["instrumentType"] == "share" && instrument["classCode"] == "TQBR") ||
          precious_metal?(instrument)
      end
      shares, others = instruments.partition { |instrument| instrument["instrumentType"] == "share" }
      shares + others
    end
    def instrument(uid)
      data = call("InstrumentsService/GetInstrumentBy", { idType: "INSTRUMENT_ID_TYPE_UID", id: uid }).fetch("instrument")
      raise Error, "Поддерживаются акции, фьючерсы и биржевые драгметаллы" unless %w[share futures].include?(data["instrumentType"]) || precious_metal?(data)
      if data["instrumentType"] == "futures"
        data.merge!(call("InstrumentsService/FutureBy", { idType: "INSTRUMENT_ID_TYPE_UID", id: uid }).fetch("instrument"))
      end
      { uid: data.fetch("uid"), ticker: data.fetch("ticker"), name: data.fetch("name"), class_code: data.fetch("classCode"), kind: data.fetch("instrumentType", "futures"), currency: data.fetch("currency"), lot: data.fetch("lot"), expiration_date: data["expirationDate"]&.to_date }
    end
    def candles(uid, timeframe)
      interval = timeframe == "day" ? "CANDLE_INTERVAL_DAY" : "CANDLE_INTERVAL_WEEK"
      from = timeframe == "day" ? 1.year.ago : 2.years.ago
      call("MarketDataService/GetCandles", { instrumentId: uid, from: from.utc.iso8601, to: Time.current.utc.iso8601, interval: interval, candleSourceType: "CANDLE_SOURCE_EXCHANGE" }).fetch("candles", []).select { |c| c["isComplete"] == true }
    end
    def self.number(value)
      BigDecimal(value.fetch("units", "0").to_s) + BigDecimal(value.fetch("nano", 0).to_s) / 1_000_000_000
    end

    def minute_candles(uid, from:, to:)
      call("MarketDataService/GetCandles", { instrumentId: uid, from: from.utc.iso8601, to: to.utc.iso8601, interval: "CANDLE_INTERVAL_1_MIN", candleSourceType: "CANDLE_SOURCE_EXCHANGE" })
        .fetch("candles", []).select { |c| c["isComplete"] == true }.map do |candle|
          { time: Time.iso8601(candle.fetch("time")) }.merge(%w[open high low close].to_h { |field| [field.to_sym, self.class.number(candle.fetch(field))] })
        end
    end
    private

    def precious_metal?(data)
      Instrument.precious_metal?(kind: data["instrumentType"], ticker: data["ticker"], class_code: data["classCode"])
    end
  end
end
