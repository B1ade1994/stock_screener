require 'digest'
require 'fileutils'
require 'zlib'

snapshot_at = Time.current
output_dir = Rails.root.join('tmp', 'historical-replay-20261016')
FileUtils.mkdir_p(output_dir)
datasets = []
# Read-only, repeatable snapshot. The replay itself only receives arrays.
if ARGV.first == 'frozen'
  datasets = %w[SP500F GLDRUB_TOM BTCUSDperpA].map do |ticker|
    input = JSON.parse(Zlib::GzipReader.open(output_dir.join("#{ticker}-inputs.json.gz"), &:read))
    { instrument: Instrument.new(input.fetch('instrument')), through: Time.iso8601(input.fetch('through')),
      minutes: input.fetch('minutes').map { |attrs| ReversalMinute.new(attrs) },
      days: input.fetch('days').map { |attrs| Candle.new(attrs) },
      weeks: input.fetch('weeks').map { |attrs| Candle.new(attrs) },
      volume_samples: input.fetch('volume_samples').map { |attrs| MinuteVolumeSample.new(attrs) } }
  end
  snapshot_at = datasets.first.fetch(:through)
else
 ActiveRecord::Base.transaction(isolation: :repeatable_read) do
  ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
  Instrument.where(ticker: %w[SP500F GLDRUB_TOM BTCUSDperpA]).order(:id).each do |instrument|
    datasets << { instrument: instrument,
      minutes: instrument.reversal_minutes.where('time <= ?', snapshot_at - 95.seconds).order(:time).to_a,
      days: instrument.candles.where(timeframe: 'day', data_source: 't_invest').where('time <= ?', snapshot_at - 1.day).order(:time).to_a,
      weeks: instrument.candles.where(timeframe: 'week', data_source: 't_invest').where('time <= ?', snapshot_at - 7.days).order(:time).to_a,
      volume_samples: instrument.minute_volume_samples.order(:time).to_a,
      through: snapshot_at }
  end
 end
end

source_files = %w[historical_strategy_replay historical_replay_results daily_retest_setup daily_retest_levels daily_support_bounce_setup
  technical_studies reversal_tracker reversal_research directional_hints directional_hint_research volume_quality market_indicators
  level_strength level_builder level_lifecycle].map { |name| Rails.root.join('app/services', "#{name}.rb") } +
  %w[levels reversal volume shock_reversal].map { |name| Rails.root.join('app/services/detectors', "#{name}.rb") }
report = { version: HistoricalStrategyReplay::VERSION, snapshot_at: snapshot_at.iso8601,
  code_sha256: source_files.to_h { |path| [path.relative_path_from(Rails.root).to_s, Digest::SHA256.file(path).hexdigest] },
  protocol: { decisions: 'Только доступный префикс: минута +95 секунд; день +24 часа +1 секунда; неделя +7 дней +1 секунда.',
    minute_entry: 'Открытие следующей полной минуты строго после решения; далее полные 15/30/60 минут одной сессии.',
    daily_entry: 'Открытие первой дневной свечи строго после решения; 1/3/5/10 свечей. Для daily_retest и bounce стоп/2R, худший порядок при неоднозначности.',
    selection: 'Одна неперекрывающаяся позиция внутри каждого инструмента/алгоритма/горизонта. Неполные исходы не освобождают слот.',
    levels: 'Зоны, роли, относительная сила и EMA строятся заново из префиксов. Только собственные свечи t_invest; SPY исключён.',
    costs: HistoricalReplayResults::COSTS, costs_unit: 'процентных пунктов за полный круг; чувствительность, не фактические расходы',
    uncertainty: '95% bootstrap по дням, 2000 повторов; при одном дне интервал неизвестен.',
    limitations: ['OHLCV не восстанавливает порядок сделок внутри минуты: crossing и false_breakout — версия на закрытиях минут.',
      'Для объёма используется реальный суммарный объём; BUY/SELL не выдумываются.',
      'Архивные directional v1/v2 и shock проверяются отдельно; в живой системе отключены.',
      'Используются сохранённые финальные свечи; фактические исторические задержки и исправления поставщика неизвестны.',
      'Текущие правила и настройки фиксированы на всём периоде. Это историческая диагностика, не независимая проверка новых гипотез на будущих данных.',
      'При недостатке минут или будущих дневных свечей результат неизвестен. Плечо, исполнение и реальная доходность портфеля не моделируются.'] }, instruments: [] }

datasets.each do |data|
  ticker = data[:instrument].ticker
  input_snapshot = { instrument: data[:instrument].attributes.slice('id', 'ticker', 'volume_multiplier', 'minimum_volume',
    'volume_noise_filter', 'volume_min_change_percent'), through: snapshot_at.iso8601,
    minutes: data[:minutes].map { |b| b.attributes.except('id','instrument_id','created_at','updated_at','source_session') },
    days: data[:days].map { |b| b.attributes.except('id','instrument_id','created_at','updated_at') },
    weeks: data[:weeks].map { |b| b.attributes.except('id','instrument_id','created_at','updated_at') },
    volume_samples: data[:volume_samples].map { |b| b.attributes.except('id','instrument_id') } }
  input_json = JSON.generate(input_snapshot)
  Zlib::GzipWriter.open(output_dir.join("#{ticker}-inputs.json.gz")) { |gz| gz.write(input_json) }
  puts "#{ticker}: replay starts (#{data[:minutes].size} minutes / #{data[:days].size} days)"
  $stdout.flush
  replay = HistoricalStrategyReplay.new(**data).run
  detected = Marshal.load(Marshal.dump(replay.events))
  signature = Digest::SHA256.hexdigest(JSON.generate(detected))
  rows = HistoricalReplayResults.new(events: replay.events, minutes: data[:minutes], days: data[:days], through: snapshot_at).call
  boundary = data[:minutes][data[:minutes].size * 2 / 3]&.time || data[:days][data[:days].size * 2 / 3].time
  cutoff = boundary + 95.seconds
  prefix_data = data.merge(through: cutoff)
  prefix = HistoricalStrategyReplay.new(**prefix_data).run
  expected = detected.select { |event| Time.iso8601(event[:at]) <= cutoff }
  prefix_ok = JSON.generate(expected) == JSON.generate(prefix.events)
  unless prefix_ok
    File.write(output_dir.join("#{ticker}-prefix-diff.json"), JSON.pretty_generate(
      expected_size: expected.size, actual_size: prefix.events.size,
      first_difference: expected.zip(prefix.events).find { |a,b| JSON.generate(a) != JSON.generate(b) }))
  end
  raise "Future-prefix invariance failed: #{ticker}" unless prefix_ok
  events_path = output_dir.join("#{ticker}-events.json")
  File.write(events_path, JSON.pretty_generate(replay.events))
  coverage = %i[minutes days weeks].to_h do |key|
    bars = data[key]
    [key, { count: bars.size, from: bars.first&.time&.iso8601, to: bars.last&.time&.iso8601 }]
  end
  report[:instruments] << { ticker: ticker, coverage: coverage, diagnostics: replay.diagnostics, rows: rows,
    candidate_states: replay.states, event_file: events_path.basename.to_s, detection_sha256: signature,
    input_sha256: Digest::SHA256.hexdigest(input_json),
    no_future_check: { passed: prefix_ok, cutoff: cutoff.iso8601, identical_events: expected.size } }
  puts "#{ticker}: #{detected.size} events; prefix check #{prefix_ok}; results saved"
  $stdout.flush
end
File.write(output_dir.join('report.json'), JSON.pretty_generate(report))
puts output_dir.join('report.json')
