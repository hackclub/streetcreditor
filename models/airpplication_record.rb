class ShipsRecord < AirctiveRecord::Base
  self.base_key = ENV.fetch("SHIPS_BASE_KEY")
end

class ConfigRecord < AirctiveRecord::Base
  self.base_key = ENV.fetch("CONFIG_BASE_KEY")
end
