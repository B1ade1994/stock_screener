class CreateScreener < ActiveRecord::Migration[8.1]
  def change
    create_table :instruments do |t|
      t.string :uid, null: false
      t.string :ticker, :name, :class_code, :kind, :currency, null: false
      t.integer :lot, default: 1, null: false
      t.date :expiration_date
      t.boolean :enabled, :volume_enabled, :breakout_enabled, default: true, null: false
      t.decimal :volume_multiplier, precision: 8, scale: 2, default: 3, null: false
      t.integer :minimum_volume, default: 10, null: false
      t.decimal :last_price, precision: 24, scale: 9
      t.datetime :last_trade_at, :history_synced_at
      t.string :history_error
      t.timestamps
    end
    add_index :instruments, :uid, unique: true
    create_table :candles do |t|
      t.references :instrument, null: false, foreign_key: true
      t.string :timeframe, null: false
      t.datetime :time, null: false
      [:open, :high, :low, :close].each { |f| t.decimal f, precision: 24, scale: 9, null: false }
      t.bigint :volume, null: false
    end
    add_index :candles, [:instrument_id, :timeframe, :time], unique: true
    create_table :price_levels do |t|
      t.references :instrument, null: false, foreign_key: true
      t.string :timeframe, :side, :source, null: false
      t.decimal :price, precision: 24, scale: 9, null: false
      t.integer :touches, default: 1, null: false
      t.boolean :active, default: true, null: false
      t.datetime :last_alert_at
      t.timestamps
    end
    create_table :market_minutes do |t|
      t.references :instrument, null: false, foreign_key: true
      t.datetime :time, null: false
      t.string :session, null: false
      t.bigint :buy, :sell, :unknown, :trades, default: 0, null: false
      t.boolean :complete, default: false, null: false
    end
    add_index :market_minutes, [:instrument_id, :time, :session], unique: true
    create_table :signals do |t|
      t.references :instrument, null: false, foreign_key: true
      t.string :kind, :event_key, :title, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :details, default: {}, null: false
      t.timestamps
    end
    add_index :signals, :event_key, unique: true
    create_table :collector_states do |t|
      t.string :name, null: false
      t.string :status, :message
      t.datetime :heartbeat_at
      t.timestamps
    end
    add_index :collector_states, :name, unique: true
  end
end
