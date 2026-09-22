# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_22_000200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "candles", force: :cascade do |t|
    t.decimal "close", precision: 24, scale: 9, null: false
    t.string "data_source", default: "t_invest", null: false
    t.decimal "high", precision: 24, scale: 9, null: false
    t.bigint "instrument_id", null: false
    t.decimal "low", precision: 24, scale: 9, null: false
    t.decimal "open", precision: 24, scale: 9, null: false
    t.bigint "reference_volume"
    t.datetime "time", null: false
    t.string "timeframe", null: false
    t.bigint "volume"
    t.index ["instrument_id", "timeframe", "time"], name: "index_candles_on_instrument_id_and_timeframe_and_time", unique: true
    t.index ["instrument_id"], name: "index_candles_on_instrument_id"
  end

  create_table "collector_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "heartbeat_at"
    t.string "message"
    t.string "name", null: false
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_collector_states_on_name", unique: true
  end

  create_table "instruments", force: :cascade do |t|
    t.boolean "breakout_enabled", default: true, null: false
    t.string "class_code", null: false
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.boolean "enabled", default: true, null: false
    t.date "expiration_date"
    t.string "history_error"
    t.datetime "history_synced_at"
    t.string "kind", null: false
    t.decimal "last_price", precision: 24, scale: 9
    t.datetime "last_reversal_minute_at"
    t.datetime "last_trade_at"
    t.integer "lot", default: 1, null: false
    t.integer "minimum_volume", default: 10, null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.boolean "reversal_enabled", default: true, null: false
    t.datetime "reversal_history_checked_at"
    t.string "reversal_history_error"
    t.string "ticker", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.boolean "volume_enabled", default: true, null: false
    t.decimal "volume_multiplier", precision: 8, scale: 2, default: "3.0", null: false
    t.index ["position"], name: "index_instruments_on_position"
    t.index ["uid"], name: "index_instruments_on_uid", unique: true
  end

  create_table "market_minutes", force: :cascade do |t|
    t.bigint "buy", default: 0, null: false
    t.decimal "close_price", precision: 24, scale: 9
    t.boolean "complete", default: false, null: false
    t.decimal "high_price", precision: 24, scale: 9
    t.bigint "instrument_id", null: false
    t.decimal "low_price", precision: 24, scale: 9
    t.decimal "open_price", precision: 24, scale: 9
    t.bigint "sell", default: 0, null: false
    t.string "session", null: false
    t.datetime "time", null: false
    t.bigint "trades", default: 0, null: false
    t.bigint "unknown", default: 0, null: false
    t.index ["instrument_id", "time", "session"], name: "index_market_minutes_on_instrument_id_and_time_and_session", unique: true
    t.index ["instrument_id"], name: "index_market_minutes_on_instrument_id"
  end

  create_table "price_levels", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.jsonb "assessment", default: {}, null: false
    t.decimal "atr", precision: 24, scale: 9
    t.jsonb "breakout", default: {}, null: false
    t.boolean "chart_visible", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "evaluated_at"
    t.bigint "instrument_id", null: false
    t.datetime "last_alert_at"
    t.decimal "lower_price", precision: 24, scale: 9
    t.decimal "price", precision: 24, scale: 9, null: false
    t.string "side", null: false
    t.string "source", null: false
    t.string "status", default: "confirmed", null: false
    t.string "timeframe", null: false
    t.integer "touches", default: 1, null: false
    t.datetime "updated_at", null: false
    t.decimal "upper_price", precision: 24, scale: 9
    t.index ["instrument_id"], name: "index_price_levels_on_instrument_id"
  end

  create_table "reversal_minutes", force: :cascade do |t|
    t.decimal "close_price", precision: 24, scale: 9, null: false
    t.string "data_source", null: false
    t.decimal "high_price", precision: 24, scale: 9, null: false
    t.bigint "instrument_id", null: false
    t.decimal "low_price", precision: 24, scale: 9, null: false
    t.decimal "open_price", precision: 24, scale: 9, null: false
    t.string "source_session"
    t.datetime "time", null: false
    t.bigint "volume", null: false
    t.index ["instrument_id", "time"], name: "index_reversal_minutes_on_instrument_id_and_time", unique: true
    t.index ["instrument_id"], name: "index_reversal_minutes_on_instrument_id"
  end

  create_table "signal_reactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "last_error"
    t.datetime "next_check_at"
    t.datetime "reference_at", null: false
    t.decimal "reference_price", precision: 24, scale: 9
    t.jsonb "results", default: {}, null: false
    t.bigint "signal_id", null: false
    t.datetime "updated_at", null: false
    t.index ["next_check_at"], name: "index_signal_reactions_on_next_check_at", where: "(next_check_at IS NOT NULL)"
    t.index ["signal_id"], name: "index_signal_reactions_on_signal_id", unique: true
  end

  create_table "signals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.string "episode_direction"
    t.string "event_key", null: false
    t.bigint "instrument_id", null: false
    t.string "kind", null: false
    t.datetime "last_occurred_at"
    t.datetime "occurred_at", null: false
    t.string "reversal_status"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["event_key"], name: "index_signals_on_event_key", unique: true
    t.index ["instrument_id", "episode_direction", "occurred_at"], name: "index_signals_on_episode_window"
    t.index ["instrument_id", "occurred_at"], name: "index_signals_on_reversals", where: "((kind)::text = 'reversal'::text)"
    t.index ["instrument_id"], name: "index_signals_on_instrument_id"
  end

  add_foreign_key "candles", "instruments"
  add_foreign_key "market_minutes", "instruments"
  add_foreign_key "price_levels", "instruments"
  add_foreign_key "reversal_minutes", "instruments"
  add_foreign_key "signal_reactions", "signals", on_delete: :cascade
  add_foreign_key "signals", "instruments"
end
