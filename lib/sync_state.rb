require "sqlite3"
require "time"

class SyncState
  DEFAULT_PATH = ENV.fetch("SYNC_STATE_PATH", File.expand_path("../sync_state.db", __dir__))

  def initialize(path = DEFAULT_PATH)
    @db = SQLite3::Database.new(path)
    @db.results_as_hash = true
    @db.execute("PRAGMA journal_mode=WAL")
    @db.execute("PRAGMA busy_timeout=5000")
    @lock = Mutex.new
    migrate!
  end

  def get(email)
    row = sync { @db.get_first_row("SELECT * FROM shippers WHERE email = ?", email) }
    return nil unless row
    { "slack_id" => row["slack_id"], "ship_date" => row["ship_date"],
      "alt" => row["alt"], "synced_at" => row["synced_at"] }
  end

  def set(email, slack_id:, ship_date:, alt:)
    sync do
      @db.execute(<<~SQL, [email, slack_id, ship_date.to_s, alt, Time.now.iso8601])
        INSERT INTO shippers (email, slack_id, ship_date, alt, synced_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(email) DO UPDATE SET
          slack_id = excluded.slack_id,
          ship_date = excluded.ship_date,
          alt = excluded.alt,
          synced_at = excluded.synced_at
      SQL
    end
  end

  def each_shipper
    rows = sync { @db.execute("SELECT * FROM shippers") }
    rows.each do |row|
      yield row["email"], {
        "slack_id" => row["slack_id"],
        "ship_date" => row["ship_date"],
        "alt" => row["alt"],
        "synced_at" => row["synced_at"]
      }
    end
  end

  def recent_shippers(limit = 50)
    sync { @db.execute("SELECT * FROM shippers ORDER BY synced_at DESC LIMIT ?", limit) }
  end

  def last_sweep_at
    meta_get("last_sweep_at")
  end

  def touch_sweep!
    meta_set("last_sweep_at", Time.now.iso8601)
  end

  # airtable webhook bookkeeping. cursor is the *next* cursor to fetch from;
  # forgetting it means every ping replays the last 7 days of payloads.
  def webhook_cursor(webhook_id)
    meta_get("webhook:#{webhook_id}:cursor")&.to_i
  end

  def set_webhook_cursor(webhook_id, base_id, cursor)
    meta_set("webhook:#{webhook_id}:base", base_id)
    meta_set("webhook:#{webhook_id}:cursor", cursor.to_s)
  end

  def webhook_refreshed_at(webhook_id)
    meta_get("webhook:#{webhook_id}:refreshed_at")
  end

  def touch_webhook_refresh!(webhook_id)
    meta_set("webhook:#{webhook_id}:refreshed_at", Time.now.iso8601)
  end

  # => [[webhook_id, base_id], ...] for every webhook that has ever pinged us
  def known_webhooks
    rows = sync { @db.execute("SELECT key, value FROM meta WHERE key LIKE 'webhook:%:base'") }
    rows.map { |r| [r["key"].split(":")[1], r["value"]] }
  end

  def seeded?
    stats[:total] > 0
  end

  def stats
    row = sync { @db.get_first_row("SELECT COUNT(*) AS c FROM shippers") }
    { total: row["c"], last_sweep_at: last_sweep_at }
  end

  private

  def sync(&block) = @lock.synchronize(&block)

  def meta_get(key)
    row = sync { @db.get_first_row("SELECT value FROM meta WHERE key = ?", key) }
    row&.dig("value")
  end

  def meta_set(key, value)
    sync do
      @db.execute(
        "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [key, value]
      )
    end
  end

  def migrate!
    @db.execute_batch(<<~SQL)
      CREATE TABLE IF NOT EXISTS shippers (
        email TEXT PRIMARY KEY,
        slack_id TEXT,
        ship_date TEXT,
        alt TEXT,
        synced_at TEXT
      );
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
      );
    SQL
  end
end
