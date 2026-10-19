class MarketSignal < ApplicationRecord
  self.table_name = "signals"
  belongs_to :instrument
  has_many :reactions, class_name: "SignalReaction", foreign_key: :signal_id, dependent: :delete_all
  has_one :reaction, -> { where(phase: 'initial') }, class_name: "SignalReaction", foreign_key: :signal_id
  has_one :confirmation_reaction, -> { where(phase: 'confirmation') }, class_name: "SignalReaction", foreign_key: :signal_id
  before_save :capture_confirmation_time
  before_create :capture_technical_context
  after_create :start_price_tracking
  after_save :start_confirmation_tracking

  scope :visible, -> { where(research_only: false) }
  scope :recent_activity, -> { order(Arel.sql("COALESCE(last_occurred_at, occurred_at) DESC, signals.id DESC")) }

  def episode? = kind == "volume" && episode_direction.present?
  def price_direction
    details["price_direction"] if kind == "volume"
  end

  # Existing cards get consistent price wording without rewriting stored decisions.
  def display_title
    return title unless episode?
    label = { 'up' => 'Объём с ростом цены', 'down' => 'Объём с падением цены',
      'flat' => 'Объём без изменения цены' }.fetch(price_direction, 'Аномальный объём')
    "#{label} · объём до ×#{details['max_ratio'] || details['ratio']}"
  end

  private

  def capture_technical_context
    # Paired experiments may copy their parent's details; their decision is new.
    self.details = details.except('technical_context', 'technical_study')
    snapshot = TechnicalContext.capture(self)
    if snapshot
      self.details = details.merge('technical_context' => snapshot)
      state = TechnicalStudies.initial_state(self)
      self.details = details.merge('technical_study' => state) if state
    end
  end

  def capture_confirmation_time
    return unless %w[reversal directional_hint volume_followthrough].include?(kind) && will_save_change_to_reversal_status? && reversal_status == 'confirmed'
    self.confirmed_at ||= Time.current
  end

  def start_confirmation_tracking
    return unless %w[reversal directional_hint volume_followthrough].include?(kind) && saved_change_to_reversal_status? && reversal_status == 'confirmed' && confirmed_at
    reference = Time.at((confirmed_at.to_i / 60 + 1) * 60).utc
    reactions.find_or_create_by!(phase: 'confirmation') do |reaction|
      reaction.reference_at = reference
      reaction.next_check_at = reference + 5.minutes + SignalReaction::SETTLE_DELAY
    end
  end

  def start_price_tracking
    return if kind.in?([DailyRetestResearch::KIND, DailySupportBounceResearch::KIND, IntradaySupportBounce::KIND])
    reference = Time.at((created_at.to_i / 60 + 1) * 60).utc
    create_reaction!(reference_at: reference, next_check_at: reference + 5.minutes + SignalReaction::SETTLE_DELAY)
  end
end
