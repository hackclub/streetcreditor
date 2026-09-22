require "bundler/setup"
require "dotenv/load"
require "norairrecord"
require "airctiverecord"
require "slack-ruby-client"

Norairrecord.api_key = ENV.fetch("AIRTABLE_API_KEY")

require File.join(__dir__, "models", "airpplication_record")
Dir[File.join(__dir__, "models", "*.rb")].each { |f| require f }
Dir[File.join(__dir__, "lib", "*.rb")].each { |f| require f }
