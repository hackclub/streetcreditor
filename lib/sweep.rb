require "set"
require "date"

# the daily incremental sync, factored out so both bin/sweep and the in-process
# timer in webhook.rb can run it. runs wherever the sync-state volume is mounted
# (the deployment pod), which the orchard job could not do.
module Sweep
  def self.run(state:, writers:, readers:, log: ->(m) { puts m })
    config = Pipeline.load_config
    log.("sweep: #{config[:aliases].size} aliases, #{config[:overrides].size} overrides")

    # new/changed projects since the last sweep. a filtered query, not the full
    # table scan that hangs in-pod.
    if state.last_sweep_at
      cutoff = (Date.parse(state.last_sweep_at) - 1).to_s
      projects = ApprovedProject.where("IS_AFTER({Approved At}, '#{cutoff}')").to_a
      log.("sweep: #{projects.size} projects changed since #{cutoff}")
      latest = Pipeline.aggregate_ships(projects, config)
      new_changes = Pipeline.diff(latest, state)
      Pipeline.resolve_slack_ids!(new_changes, readers, state)
    else
      log.("sweep: no previous sweep recorded; skipping new-project scan")
      new_changes = []
    end

    # relative-time strings ("2 days ago") tick over daily, so refresh them for
    # everyone already in state.
    alt_changes = Pipeline.refresh_alt_strings(state)
    seen = new_changes.map { |c| c[:email] }.to_set
    alt_changes.reject! { |c| seen.include?(c[:email]) }

    all_changes = new_changes + alt_changes
    log.("sweep: #{new_changes.size} new, #{alt_changes.size} alt-refresh, #{all_changes.size} to push")

    if all_changes.any?
      result = Pipeline.push_to_slack!(all_changes, writers, state, progress: false)
      log.("sweep: #{result[:success]} updated, #{result[:errors]} errors")
    end

    state.touch_sweep!

    # keep the airtable webhooks alive (PAT webhooks die 7 days after last refresh)
    state.known_webhooks.each do |webhook_id, base_id|
      expires = AirtableWebhooks.refresh(base_id, webhook_id)
      log.("sweep: webhook #{webhook_id} refreshed, expires #{expires}") if expires
    end

    log.("sweep: done")
  end
end
