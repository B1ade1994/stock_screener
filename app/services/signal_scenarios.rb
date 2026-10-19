# Only persisted links identify a scenario; proximity in time is not evidence.
class SignalScenarios
  PARENT_FIELDS = %w[control_id source_signal_id parent_signal_id source_id].freeze
  LEVEL_KINDS = %w[confirmed retest held_breakout failed_breakout].freeze
  attr_reader :unresolved_ids

  def initialize(signals)
    @signals = signals.to_a
    @by_id = @signals.index_by(&:id)
    @roots = {}
    @levels = {}
    @unresolved_ids = []
    frontier = @signals
    loop do
      ids = frontier.filter_map { |s| parent_id(s) }.uniq - @by_id.keys
      break if ids.empty?
      frontier = MarketSignal.where(id: ids).includes(:reaction).to_a
      break if frontier.empty?
      @by_id.merge!(frontier.index_by(&:id))
    end
  end

  def root_for(signal)
    return @roots[signal.id] if @roots.key?(signal.id)
    current = signal
    visited = []
    while (id = parent_id(current))
      parent = @by_id[id]
      if !parent || parent.instrument_id != signal.instrument_id || visited.include?(id) || id == current.id
        @unresolved_ids |= [signal.id]
        return @roots[signal.id] = signal
      end
      visited << current.id
      current = parent
    end
    @roots[signal.id] = level_root(current)
  end

  def representatives = @signals.map { |s| root_for(s) }.uniq(&:id)

  def self.timeline(signal)
    # One instrument's history includes silent experiments, with eager reactions.
    signals = signal.instrument.signals.includes(:instrument, :reaction, :confirmation_reaction).order(:created_at, :id).to_a
    resolver = new(signals)
    root = resolver.root_for(signal)
    signals.select { |event| resolver.root_for(event).id == root.id }
  end

  private

  def parent_id(signal)
    value = PARENT_FIELDS.filter_map { |field| signal.details[field] }.first
    value.to_s.match?(/\A[1-9]\d*\z/) ? value.to_i : nil
  end

  def level_root(signal)
    d = signal.details
    return signal unless LEVEL_KINDS.include?(signal.kind) && d['level_id'].present? && d['breakout_started_at'].present?
    key = [signal.instrument_id, d['level_id'], d['breakout_started_at'], d['side']]
    @levels[key] ||= MarketSignal.where(instrument_id: signal.instrument_id, kind: LEVEL_KINDS)
      .where('details @> ?::jsonb', d.slice('level_id', 'breakout_started_at', 'side').to_json)
      .includes(:reaction).order(:created_at, :id).first || signal
  end
end
