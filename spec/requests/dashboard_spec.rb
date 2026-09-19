require "rails_helper"

RSpec.describe "Dashboard tabs", type: :request do
  let!(:instrument) { create_instrument }
  let!(:signal) { instrument.signals.create!(kind: "volume", title: "Аномальный объём TEST", event_key: "dashboard-volume", occurred_at: Time.current, details: { buy: 90, sell: 10, unknown: 0 }) }

  it "opens the instruments tab by default without the event feed" do
    get root_path
    page = Nokogiri::HTML(response.body)
    expect(page.at_css(".sidebar .workspace-link[aria-current='page']").text).to eq("Акции")
    expect(page.at_css("#instrument_#{instrument.id}")).to be_present
    expect(page.css(".signal")).to be_empty
    expect(page.at_css("a[href='#{root_path(tab: 'events')}']").text).to eq("Лента событий")
  end

  it "keeps the selected event feed on reload and Turbo refresh" do
    [ {}, { "Turbo-Frame" => "dashboard" } ].each do |headers|
      get root_path(tab: "events"), headers: headers
      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css(".sidebar .workspace-link[aria-current='page']").text).to eq("Лента событий") if headers.empty?
      expect(page.at_css("turbo-frame#dashboard[data-controller='refresh'] .signal").text).to include(signal.title, "BUY 90 / SELL 10")
      expect(page.at_css("#instruments-list")).to be_nil
      expect(page.at_css("#signal-sound")).to be_present if headers.empty?
    end
  end

  it "falls back to instruments for an unknown tab" do
    get root_path(tab: "unknown")
    expect(Nokogiri::HTML(response.body).at_css(".sidebar .workspace-link[aria-current='page']").text).to eq("Акции")
  end
end
