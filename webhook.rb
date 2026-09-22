require_relative "boot"
require "sinatra/base"
require "json"
require "time"
require "cgi"

class StreetCreditorWebhook < Sinatra::Base
  TABLE_ID = ApprovedProject::TABLE_ID
  FIELD_EMAIL = ApprovedProject::FIELD_EMAIL
  FIELD_APPROVED_AT = ApprovedProject::FIELD_APPROVED_AT
  OVERRIDE_TABLE_ID = ManualOverride::TABLE_ID
  OVERRIDE_FIELD_EMAIL = ManualOverride::FIELD_EMAIL
  OVERRIDE_FIELD_SHIP_DATE = ManualOverride::FIELD_SHIP_DATE
  CONFIG_TTL = 300
  REFRESH_EVERY = 24 * 60 * 60

  configure do
    set :host_authorization, permitted_hosts: [/.*/]
    set :state, SyncState.new
    set :writers, TokenPool.new(prefix: "SLACK_WRITER_TOKEN", rate: 30)
    set :readers, TokenPool.new(prefix: "SLACK_READER_TOKEN", rate: 50)
    set :config_cache, Pipeline.load_config
    set :config_loaded_at, Time.now
    secrets = [ENV["AIRTABLE_WEBHOOK_MAC_SECRET"]].compact
    i = 1
    while (val = ENV["AIRTABLE_WEBHOOK_MAC_SECRET_#{i}"])
      secrets << val
      i += 1
    end
    set :mac_secrets, secrets

    if settings.mac_secrets.empty?
      $stderr.puts "webhook: no AIRTABLE_WEBHOOK_MAC_SECRET* set — accepting unsigned pings"
    end

    # airtable wants a fast 200 and retries on timeout, so pings just get queued
    # and a single worker drains them. one worker means no two pings race on the cursor.
    set :queue, Queue.new
    set :pending, Set.new
    set :pending_lock, Mutex.new
    set :worker, Thread.new { loop { drain(settings.queue.pop) } }
  end

  get "/" do
    content_type "text/html"
    stats = settings.state.stats
    config = settings.config_cache
    recent = settings.state.recent_shippers(50)
    alive = settings.worker.alive?
    qsize = settings.queue.size

    wh_info = settings.state.known_webhooks.map { |wh_id, base_id|
      [wh_id, base_id, settings.state.webhook_cursor(wh_id),
       settings.state.webhook_refreshed_at(wh_id)]
    }

    if wh_info.empty?
      wh_section = "<i>None registered.</i> Run <tt>bin/webhook create &lt;url&gt;</tt>"
    else
      wh_rows = wh_info.map { |id, base, cur, ref|
        "<tr><td><tt>#{h id}</tt></td><td><tt>#{h base}</tt></td>" \
        "<td align=right>#{cur || '&mdash;'}</td>" \
        "<td>#{ref ? h(ref) : '<i>never</i>'}</td></tr>"
      }.join
      wh_section = "<table border=1 cellpadding=4 cellspacing=0>" \
        "<tr bgcolor=#cccccc><th>Webhook</th><th>Base</th><th>Cursor</th><th>Last Refresh</th></tr>" \
        "#{wh_rows}</table>"
    end

    if config[:overrides].empty?
      override_section = ""
    else
      rows = config[:overrides].sort_by { |_, d| d.to_s }.reverse.map { |email, date|
        alt = RelativeTime.call(date) rescue "?"
        "<tr><td>#{redact_email email}</td><td>#{h date}</td><td><i>#{h alt}</i></td></tr>"
      }.join
      override_section = "<br><table border=1 cellpadding=3 cellspacing=0>" \
        "<tr bgcolor=#cccccc><th>Email</th><th>Ship Date</th><th></th></tr>" \
        "#{rows}</table>"
    end

    if recent.empty?
      shipper_section = "<i>No shippers yet.</i> Run <tt>bin/seed</tt> first."
    else
      rows = recent.each_with_index.map { |row, i|
        bg = i.even? ? " bgcolor=#f0f0f0" : ""
        "<tr#{bg}><td>#{redact_email row['email']}</td><td>#{h row['ship_date']}</td>" \
        "<td>#{h row['alt']}</td><td><tt>#{redact_slack_id row['slack_id']}</tt></td>" \
        "<td><font size=-1>#{h row['synced_at']}</font></td></tr>"
      }.join
      shipper_section = "<table border=1 cellpadding=3 cellspacing=0 width=100%>" \
        "<tr bgcolor=#cccccc><th>Email</th><th>Ship Date</th><th>Status</th><th>Slack</th><th>Synced</th></tr>" \
        "#{rows}</table>"
    end

    status_bg = alive ? "#00cc00" : "#cc0000"
    status_fg = alive ? "#000000" : "#ffffff"
    queue_attr = qsize > 0 ? " bgcolor=#ffff00" : ""

    <<~HTML
      <html>
      <head>
      <title>streetcreditor</title>
      <meta http-equiv=refresh content=30>
      </head>
      <body bgcolor=#ffffff text=#000000 link=#0000ee vlink=#551a8b>
      <table width=100% bgcolor=#003366 cellpadding=10 cellspacing=0 border=0><tr>
      <td><font face="Verdana, Arial" color=#ffffff size=+2><b>streetcreditor</b></font></td>
      <td align=right><font face="Verdana, Arial" color=#6688aa size=-1>#{h Time.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}</font></td>
      </tr></table>
      <h3>Status</h3>
      <table border=0 cellpadding=4 cellspacing=2>
      <tr><td><b>Shippers:</b></td><td>#{stats[:total]}</td></tr>
      <tr><td><b>Last sweep:</b></td><td>#{stats[:last_sweep_at] ? h(stats[:last_sweep_at]) : '<i>never</i>'}</td></tr>
      <tr><td><b>Worker:</b></td><td bgcolor="#{status_bg}"><font color="#{status_fg}"><b>#{alive ? 'ALIVE' : 'DEAD'}</b></font></td></tr>
      <tr><td><b>Queue:</b></td><td#{queue_attr}>#{qsize}</td></tr>
      </table>
      <hr noshade size=1>
      <h3>Webhooks</h3>
      #{wh_section}
      <hr noshade size=1>
      <h3>Configuration</h3>
      <p>#{config[:aliases].size} email aliases, #{config[:overrides].size} manual overrides
      &mdash; <a href="https://airtable.com/#{h ENV['CONFIG_BASE_KEY']}">edit in airtable</a></p>
      #{override_section}
      <hr noshade size=1>
      <h3>Recent Updates</h3>
      <font size=-1>#{recent.size} of #{stats[:total]}</font><br>
      #{shipper_section}
      <hr noshade size=1>
      <font size=-2 color=#888888>streetcreditor &bull; <a href="/health">json</a></font>
      </body></html>
    HTML
  end

  get "/health" do
    stats = settings.state.stats
    content_type :json
    {
      status: "ok",
      shippers: stats[:total],
      last_sweep: stats[:last_sweep_at],
      queued: settings.queue.size,
      worker_alive: settings.worker.alive?
    }.to_json
  end

  post "/airtable/webhook" do
    request.body.rewind if request.body.respond_to?(:rewind)
    body = request.body.read

    unless settings.mac_secrets.empty?
      sig = request.env["HTTP_X_AIRTABLE_CONTENT_MAC"]
      halt 401, "bad signature" unless settings.mac_secrets.any? { |s| AirtableWebhooks.valid_signature?(body, sig, s) }
    end

    payload = JSON.parse(body) rescue halt(400, "bad json")
    webhook_id = payload.dig("webhook", "id")
    base_id = payload.dig("base", "id")
    halt 400, "missing webhook or base id" unless webhook_id && base_id

    enqueue(base_id, webhook_id)
    status 200
    "ok"
  end

  helpers do
    def h(text) = CGI.escapeHTML(text.to_s)

    def redact_email(email)
      local, domain = email.to_s.split("@", 2)
      return "***" unless local && domain
      "#{h local[0]}***@#{h domain}"
    end

    def redact_slack_id(sid)
      return "—" unless sid && sid.length > 4
      "#{h sid[0]}...#{h sid[-4..]}"
    end

    def enqueue(base_id, webhook_id)
      key = [base_id, webhook_id]
      settings.pending_lock.synchronize do
        return if settings.pending.include?(key)
        settings.pending << key
      end
      settings.queue << key
    end
  end

  class << self
    def drain((base_id, webhook_id))
      refresh_config_if_stale!
      process_webhook(base_id, webhook_id)
    rescue => e
      $stderr.puts "webhook: worker error for #{webhook_id}: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.first(5).map { |l| "    #{l}" }
    ensure
      settings.pending_lock.synchronize { settings.pending.delete([base_id, webhook_id]) }
    end

    private

    def refresh_config_if_stale!
      return unless Time.now - settings.config_loaded_at > CONFIG_TTL
      settings.config_cache = Pipeline.load_config
      settings.config_loaded_at = Time.now
    end

    def process_webhook(base_id, webhook_id)
      state = settings.state
      ships = {}
      overrides = {}

      next_cursor = AirtableWebhooks.each_payload(base_id, webhook_id, cursor: state.webhook_cursor(webhook_id)) do |p|
        changed = p["changedTablesById"] || {}

        if (table_changes = changed[TABLE_ID])
          (table_changes["createdRecordsById"] || {}).each do |id, record|
            collect(ships, id, record["cellValuesByFieldId"])
          end
          (table_changes["changedRecordsById"] || {}).each do |id, record|
            collect(ships, id, record.dig("current", "cellValuesByFieldId"))
          end
        end

        if (override_changes = changed[OVERRIDE_TABLE_ID])
          (override_changes["createdRecordsById"] || {}).each do |id, record|
            collect_override(overrides, id, record["cellValuesByFieldId"])
          end
          (override_changes["changedRecordsById"] || {}).each do |id, record|
            collect_override(overrides, id, record.dig("current", "cellValuesByFieldId"))
          end
        end
      end

      ships.merge(overrides).each do |email, ship_date|
        Pipeline.update_single(
          email: email,
          ship_date: ship_date,
          writers: settings.writers,
          readers: settings.readers,
          state: state,
          config: settings.config_cache
        )
      rescue => e
        $stderr.puts "webhook: error updating #{email}: #{e.message}"
      end

      unless overrides.empty?
        settings.config_cache = Pipeline.load_config
        settings.config_loaded_at = Time.now
      end

      state.set_webhook_cursor(webhook_id, base_id, next_cursor) if next_cursor
      refresh_if_due(base_id, webhook_id)
    end

    def collect(ships, record_id, fields)
      fields ||= {}
      return unless fields.key?(FIELD_APPROVED_AT) || fields.key?(FIELD_EMAIL)

      email = fields[FIELD_EMAIL]
      approved_at = fields[FIELD_APPROVED_AT]

      unless email && approved_at
        project = ApprovedProject.find(record_id)
        email = project.email_normalized || project.email
        approved_at = project.approved_at
      end
      return unless email && approved_at

      email = email.downcase.strip
      ships[email] = approved_at if !ships[email] || approved_at > ships[email]
    rescue => e
      $stderr.puts "webhook: couldn't resolve record #{record_id}: #{e.message}"
    end

    def collect_override(overrides, record_id, fields)
      fields ||= {}
      return unless fields.key?(OVERRIDE_FIELD_EMAIL) || fields.key?(OVERRIDE_FIELD_SHIP_DATE)

      email = fields[OVERRIDE_FIELD_EMAIL]
      ship_date = fields[OVERRIDE_FIELD_SHIP_DATE]

      unless email && ship_date
        record = ManualOverride.find(record_id)
        email = record.email
        ship_date = record.ship_date
      end
      return unless email && ship_date

      email = email.downcase.strip
      overrides[email] = ship_date if !overrides[email] || ship_date > overrides[email]
    rescue => e
      $stderr.puts "webhook: couldn't resolve override #{record_id}: #{e.message}"
    end

    def refresh_if_due(base_id, webhook_id)
      last = settings.state.webhook_refreshed_at(webhook_id)
      return if last && Time.now - Time.parse(last) < REFRESH_EVERY

      expires = AirtableWebhooks.refresh(base_id, webhook_id)
      return unless expires
      settings.state.touch_webhook_refresh!(webhook_id)
      $stderr.puts "webhook: refreshed #{webhook_id}, now expires #{expires}"
    end
  end
end
