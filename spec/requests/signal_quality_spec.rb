require 'rails_helper'
RSpec.describe 'Signal quality controls', type: :request do
  let(:instrument) { create_instrument }
  def event(**attrs)
    instrument.signals.create!({kind:'volume',title:'Noise',event_key:SecureRandom.uuid,occurred_at:Time.current}.merge(attrs))
  end
  it 'keeps silent research out of both feeds and sound, but includes it in statistics' do
    visible=event(title:'Visible');hidden=event(research_only:true)
    [root_path(tab:'events', event_filter:'volume'), instrument_path(instrument), events_instrument_path(instrument)].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="market_signal_#{visible.id}"))
      expect(response.body).not_to include(%(id="market_signal_#{hidden.id}"))
    end
    get latest_signals_path
    expect(response.parsed_body['latest_id']).to eq(visible.id)
    get statistics_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Объём: отсеянные','Эксперимент: экстремум и ретест')
  end
  it 'allows per-instrument filter tuning and rejects invalid thresholds' do
    patch instrument_path(instrument),params:{instrument:{volume_noise_filter:'0',volume_min_change_percent:'0.12'}}
    expect(instrument.reload).to have_attributes(volume_noise_filter:false,volume_min_change_percent:BigDecimal('0.12'))
    patch instrument_path(instrument),params:{instrument:{volume_min_change_percent:'-1'}}
    expect(instrument.reload.volume_min_change_percent).to eq(BigDecimal('0.12'))
    get instrument_path(instrument)
    expect(response.body).to include('Фильтр шума: движение цены и время сессии')
  end
end
