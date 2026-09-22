class TokenPool
  MAX_RETRIES = 5
  attr_reader :clients

  def initialize(prefix:, rate:)
    tokens = load_tokens(prefix)
    @clients = tokens.map do |token|
      {
        client: Slack::Web::Client.new(token: token),
        limiter: RateLimiter.new(rate)
      }
    end
  end

  def size
    @clients.size
  end

  def with_client(index: nil)
    entry = if index
      @clients[index % @clients.size]
    else
      @clients.max_by { |e| e[:limiter].available }
    end

    # `retry` re-runs the whole begin block, so the counter has to live outside it
    retries = 0
    begin
      entry[:limiter].wait
      yield entry[:client]
    rescue Slack::Web::Api::Errors::TooManyRequestsError => e
      retries += 1
      raise if retries > MAX_RETRIES
      retry_after = e.response.headers["retry-after"].to_i
      entry[:limiter].backoff(retry_after)
      retry
    end
  end

  private

  def load_tokens(prefix)
    tokens = []
    tokens << ENV[prefix] if ENV[prefix]

    i = 1
    loop do
      val = ENV["#{prefix}_#{i}"]
      break unless val
      tokens << val
      i += 1
    end

    raise "no #{prefix} or #{prefix}_1/2/... found in env" if tokens.empty?
    tokens
  end
end
