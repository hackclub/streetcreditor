require "net/http"
require "uri"
require "json"
require "openssl"
require "base64"

# thin wrapper over the bits of the airtable webhooks API we need:
# https://airtable.com/developers/web/api/webhooks-overview
module AirtableWebhooks
  API = "https://api.airtable.com/v0/bases"

  # airtable signs the ping body with hmac-sha256 using the macSecretBase64
  # returned when the webhook was created. header looks like
  #   X-Airtable-Content-MAC: hmac-sha256=<hex>
  def self.valid_signature?(body, header, secret_base64)
    return false if header.nil? || secret_base64.nil?
    secret = Base64.decode64(secret_base64)
    expected = "hmac-sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    OpenSSL.fixed_length_secure_compare(expected, header)
  rescue ArgumentError
    false # lengths differ
  end

  # yields each payload from `cursor` onward; returns the cursor to resume from next time.
  # if a page fails we return the cursor we got up to so nothing is skipped or replayed.
  def self.each_payload(base_id, webhook_id, cursor: nil)
    loop do
      url = "#{API}/#{base_id}/webhooks/#{webhook_id}/payloads"
      url += "?cursor=#{cursor}" if cursor

      response = request(Net::HTTP::Get.new(URI(url)))
      unless response.is_a?(Net::HTTPSuccess)
        $stderr.puts "webhook: listing payloads returned #{response.code}: #{response.body}"
        return cursor
      end

      data = JSON.parse(response.body)
      (data["payloads"] || []).each { |p| yield p }
      cursor = data["cursor"]
      return cursor unless data["mightHaveMore"]
    end
  end

  # webhooks made with a PAT expire 7 days after the last refresh
  def self.refresh(base_id, webhook_id)
    response = request(Net::HTTP::Post.new(URI("#{API}/#{base_id}/webhooks/#{webhook_id}/refresh")))
    unless response.is_a?(Net::HTTPSuccess)
      $stderr.puts "webhook: refresh of #{webhook_id} returned #{response.code}: #{response.body}"
      return nil
    end
    JSON.parse(response.body)["expirationTime"]
  end

  def self.request(req)
    req["Authorization"] = "Bearer #{ENV.fetch('AIRTABLE_API_KEY')}"
    Net::HTTP.start(req.uri.hostname, req.uri.port, use_ssl: true) { |http| http.request(req) }
  end
  private_class_method :request
end

module AirtableWebhooks
  # management. needs a PAT with the webhook:manage scope.
  def self.list(base_id)
    response = request(Net::HTTP::Get.new(URI("#{API}/#{base_id}/webhooks")))
    raise "list failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)["webhooks"]
  end

  # only fires for adds/updates that touch `watch_fields` on `table_id`, and
  # always includes `include_fields` in the payload so we rarely need to fetch the row
  def self.create(base_id, notification_url:, table_id:, watch_fields:, include_fields: [])
    req = Net::HTTP::Post.new(URI("#{API}/#{base_id}/webhooks"))
    req["Content-Type"] = "application/json"
    req.body = {
      notificationUrl: notification_url,
      specification: {
        options: {
          filters: {
            dataTypes: ["tableData"],
            recordChangeScope: table_id,
            changeTypes: ["add", "update"],
            watchDataInFieldIds: watch_fields
          },
          includes: {
            includeCellValuesInFieldIds: include_fields
          }
        }
      }
    }.to_json
    response = request(req)
    raise "create failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body) # id, macSecretBase64, expirationTime
  end

  def self.delete(base_id, webhook_id)
    response = request(Net::HTTP::Delete.new(URI("#{API}/#{base_id}/webhooks/#{webhook_id}")))
    raise "delete failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
    true
  end
end
