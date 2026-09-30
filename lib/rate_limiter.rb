class RateLimiter
  def initialize(max_per_minute)
    @max_per_minute = max_per_minute
    # start empty, not full: a full bucket lets every worker fire a whole
    # minute's allowance at once, which bursts past slack's per-app cap and
    # gets the token penalized. starting empty paces from the first call.
    @tokens = 0.0
    @last_refill = Time.now
    @mutex = Mutex.new
    @refill_rate = max_per_minute / 60.0
    @paused_until = Time.at(0)
  end

  def wait
    loop do
      sleep_time = nil

      @mutex.synchronize do
        now = Time.now

        if @paused_until > now
          sleep_time = @paused_until - now
        else
          elapsed = now - @last_refill
          @tokens = [@tokens + (elapsed * @refill_rate), @max_per_minute].min
          @last_refill = now

          if @tokens >= 1.0
            @tokens -= 1.0
            return
          else
            sleep_time = (1.0 - @tokens) / @refill_rate
          end
        end
      end

      sleep(sleep_time) if sleep_time && sleep_time > 0
    end
  end

  def backoff(seconds)
    @mutex.synchronize do
      seconds = 5 if seconds <= 0
      target = Time.now + seconds
      @paused_until = target if target > @paused_until
    end
  end

  def available
    @mutex.synchronize do
      return -1 if @paused_until > Time.now
      @tokens
    end
  end
end
