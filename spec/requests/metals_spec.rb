require "rails_helper"

RSpec.describe "Precious metals", type: :request do
  let(:uid) { SecureRandom.uuid }
  let(:client) { TInvest::Client.new }
  let(:gold) { { "uid" => uid, "ticker" => "GLDRUB_TOM", "name" => "Золото", "instrumentType" => "currency", "classCode" => "CETS", "currency" => "rub", "lot" => 1 } }

  before do
    allow(TInvest::Client).to receive(:new).and_return(client)
    allow(client).to receive(:call).with("InstrumentsService/FindInstrument", { query: "GLDRUB_TOM" }).and_return("instruments" => [gold])
    allow(client).to receive(:call).with("InstrumentsService/GetInstrumentBy", { idType: "INSTRUMENT_ID_TYPE_UID", id: uid }).and_return("instrument" => gold)
  end

  it "finds and adds gold, queues history and labels both chart and watchlist correctly" do
    get search_instruments_path(q: "GLDRUB_TOM")
    expect(response.body).to include("GLDRUB_TOM", "Драгметалл", "CETS")
    expect { post instruments_path, params: { uid: uid } }.to change(Instrument, :count).by(1).and have_enqueued_job(RefreshHistoryJob)
    instrument = Instrument.find_by!(uid: uid)
    expect(instrument).to have_attributes(kind: "currency", currency: "rub", lot: 1, expiration_date: nil)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("h1 .badge").text).to eq("Драгметалл")
    expect(response.body).not_to include("Экспирация")
    get root_path
    row = Nokogiri::HTML(response.body).at_css("#instrument_#{instrument.id}")
    expect(row.text).to include("Драгметалл", "RUB")
  end
end
