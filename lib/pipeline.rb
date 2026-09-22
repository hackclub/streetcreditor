require "ruby-progressbar"

module Pipeline
  FIELD_ID = ENV.fetch("SLACK_FIELD_ID", "Xf0BV2AV197Y")

  def self.load_config
    aliases = {}
    EmailAlias.all.each do |a|
      ak = a.alias_email&.downcase&.strip
      next if ak.nil? || ak.empty?
      aliases[ak] = a.primary_email&.downcase&.strip
    end

    overrides = {}
    ManualOverride.all.each do |o|
      ok = o.email&.downcase&.strip
      next if ok.nil? || ok.empty?
      overrides[ok] = o.ship_date
    end

    { aliases:, overrides: }
  end

  def self.canonicalize(email, aliases)
    email = email&.downcase&.strip
    aliases[email] || email
  end

  def self.aggregate_ships(projects, config)
    latest = {}

    projects.each do |project|
      email = canonicalize(project.email_normalized || project.email, config[:aliases])
      next unless email && !email.empty?

      date = project.approved_at
      next unless date

      if !latest[email] || date > latest[email]
        latest[email] = date
      end
    end

    config[:overrides].each do |email, date|
      next unless email && date
      if !latest[email] || date > latest[email]
        latest[email] = date
      end
    end

    latest
  end

  def self.diff(latest_ships, state)
    changes = []
    today = Date.today

    latest_ships.each do |email, ship_date|
      new_alt = RelativeTime.call(ship_date, today)
      existing = state.get(email)

      if !existing || existing["alt"] != new_alt || existing["ship_date"] != ship_date.to_s
        changes << {
          email: email,
          slack_id: existing&.dig("slack_id"),
          ship_date: ship_date,
          alt: new_alt
        }
      end
    end

    changes
  end

  def self.refresh_alt_strings(state)
    changes = []
    today = Date.today

    state.each_shipper do |email, entry|
      next unless entry["ship_date"] && entry["slack_id"]
      new_alt = RelativeTime.call(entry["ship_date"], today)
      next if entry["alt"] == new_alt

      changes << {
        email: email,
        slack_id: entry["slack_id"],
        ship_date: entry["ship_date"],
        alt: new_alt
      }
    rescue Date::Error
      $stderr.puts "bad ship_date for #{email}: #{entry['ship_date'].inspect}, skipping"
    end

    changes
  end

  def self.resolve_slack_ids!(changes, readers, state)
    unresolved = changes.select { |c| c[:slack_id].nil? }
    return if unresolved.empty?

    mutex = Mutex.new
    queue = Queue.new
    unresolved.each { |c| queue << c }
    readers.size.times { queue << :done }

    not_found = []
    lookup_errors = 0

    workers = readers.size.times.map do |i|
      Thread.new do
        loop do
          change = queue.pop
          break if change == :done

          readers.with_client(index: i) do |client|
            response = client.users_lookupByEmail(email: change[:email])
            slack_id = response.dig("user", "id")
            mutex.synchronize { change[:slack_id] = slack_id }
          rescue Slack::Web::Api::Errors::UsersNotFound
            mutex.synchronize { not_found << change[:email] }
          rescue Slack::Web::Api::Errors::TooManyRequestsError
            raise
          rescue => e
            mutex.synchronize do
              lookup_errors += 1
              $stderr.puts "error looking up #{change[:email]}: #{e.message}"
            end
          end
        end
      end
    end

    workers.each(&:join)
    changes.reject! { |c| c[:slack_id].nil? }

    $stderr.puts "#{not_found.size} emails not found in Slack" unless not_found.empty?
    $stderr.puts "#{lookup_errors} lookup errors" if lookup_errors > 0
  end

  def self.push_to_slack!(changes, writers, state, progress: true)
    return { success: 0, errors: 0 } if changes.empty?

    mutex = Mutex.new
    queue = Queue.new
    changes.each { |c| queue << c }
    writers.size.times { queue << :done }

    success = 0
    errors = 0

    bar = if progress
      ProgressBar.create(
        title: "Updating profiles",
        total: changes.size,
        format: "%t: |%B| %p%% %c/%C %e"
      )
    end

    workers = writers.size.times.map do |i|
      Thread.new do
        loop do
          change = queue.pop
          break if change == :done

          writers.with_client(index: i) do |client|
            client.users_profile_set(
              user: change[:slack_id],
              profile: {
                fields: {
                  FIELD_ID => {
                    value: change[:ship_date].to_s,
                    alt: change[:alt]
                  }
                }
              }
            )

            mutex.synchronize do
              state.set(
                change[:email],
                slack_id: change[:slack_id],
                ship_date: change[:ship_date],
                alt: change[:alt]
              )
              success += 1
              bar&.increment
            end
          rescue Slack::Web::Api::Errors::TooManyRequestsError
            raise
          rescue => e
            mutex.synchronize do
              errors += 1
              if bar
                bar.log "error updating #{change[:email]}: #{e.message}"
              else
                $stderr.puts "error updating #{change[:email]}: #{e.message}"
              end
              bar&.increment
            end
          end
        end
      end
    end

    workers.each(&:join)
    { success:, errors: }
  end

  def self.update_single(email:, ship_date:, writers:, readers:, state:, config: nil)
    config ||= load_config
    email = canonicalize(email, config[:aliases])
    ship_date = Date.parse(ship_date) if ship_date.is_a?(String)

    # a manual override wins if it's newer, same as aggregate_ships
    override = config[:overrides][email]
    if override
      override = Date.parse(override) rescue nil
      ship_date = override if override && override > ship_date
    end

    alt = RelativeTime.call(ship_date)

    existing = state.get(email)
    slack_id = existing&.dig("slack_id")

    if existing && existing["ship_date"]
      existing_date = Date.parse(existing["ship_date"]) rescue nil
      # never regress, and don't burn a write when nothing changed
      return true if existing_date && ship_date < existing_date
      return true if existing_date == ship_date && existing["alt"] == alt && slack_id
    end

    unless slack_id
      readers.with_client do |client|
        response = client.users_lookupByEmail(email: email)
        slack_id = response.dig("user", "id")
      rescue Slack::Web::Api::Errors::UsersNotFound
        $stderr.puts "#{email} not found in Slack"
        return false
      end
    end

    writers.with_client do |client|
      client.users_profile_set(
        user: slack_id,
        profile: {
          fields: {
            FIELD_ID => { value: ship_date.to_s, alt: alt }
          }
        }
      )
    end

    state.set(email, slack_id:, ship_date:, alt:)
    true
  end
end
