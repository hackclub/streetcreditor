module RelativeTime
  def self.call(ship_date, today = Date.today)
    ship_date = Date.parse(ship_date) if ship_date.is_a?(String)
    days = (today - ship_date).to_i
    return "today" if days < 0

    case days
    when 0          then "today"
    when 1          then "yesterday"
    when 2..6       then "#{days} days ago"
    when 7..13      then "1 week ago"
    when 14..20     then "2 weeks ago"
    when 21..27     then "3 weeks ago"
    when 28..364
      months = (days / 30.436875).round
      months = 1 if months < 1
      months == 1 ? "1 month ago" : "#{months} months ago"
    else
      years = (days / 365.25).round
      years = 1 if years < 1
      years == 1 ? "1 year ago" : "#{years} years ago"
    end
  end
end
