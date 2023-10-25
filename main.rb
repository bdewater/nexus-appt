# frozen_string_literal: true

require "net/http"
require "json"
require "redis"
require "time"
require "twilio-ruby"

# see https://ttp.cbp.dhs.gov/schedulerapi/locations/?temporary=false&inviteOnly=false&operational=true&serviceName=NEXUS
LOCATIONS = {
  5021 => "Champlain, NY",
  5025 => "Ottawa airport",
  5028 => "Montreal airport",
  5223 => "Derby Line, VT",
  # 5160 => "International Falls, MN", # good for testing, always has slots
}.freeze
REDIS = Redis.new(url: ENV["REDIS_URL"])
TWILIO = Twilio::REST::Client.new(ENV["TWILIO_ACCOUNT_SID"], ENV["TWILIO_AUTH_TOKEN"])
HEADERS = { 
  "Accept-Encoding" => "application/json, text/plain, */*",
  "Accept" => "application/json, text/plain, */*",
  "Accept-Language" => "en-US,en;q=0.9",
  "Authorization" => "",
  "DNT" => "1",
  "Origin" => "https://ttp.dhs.gov",
  "Referer" => "https://ttp.dhs.gov/",
  "Sec-Fetch-Dest" => "empty",
  "Sec-Fetch-Mode" => "cors",
  "Sec-Fetch-Site" => "same-site",
  "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36",
  "sec-ch-ua" => '"Chromium";v="104", " Not A;Brand";v="99", "Google Chrome";v="104"',
  "sec-ch-ua-mobile" => "?0",
  "sec-ch-ua-platform" => '"macOS"',
}.freeze

http = Net::HTTP.new("ttp.cbp.dhs.gov", 443).tap do |http|
  http.use_ssl = true
  # http.set_debug_output($stdout)
  http.open_timeout = 10
  http.read_timeout = 10
end

location_slots = http.start do |conn|
  response = conn.get("/schedulerapi/slots/asLocations?minimum=1&limit=5&serviceName=NEXUS", HEADERS)
  json = JSON.parse(response.body)

  locations = json.select { |center| LOCATIONS.key?(center["id"]) }
  if locations.empty?
    puts "no appointments found for locations #{LOCATIONS.keys.join(", ")} - exiting"
    exit
  end

  locations.map do |location|
    response = conn.get("/schedulerapi/slots?orderBy=soonest&limit=1&locationId=#{location["id"]}&minimum=1", HEADERS)
    JSON.parse(response.body)
  end
end

location_slots.each do |slots|
  slots.each do |slot|
    cache_key = slot.values_at("locationId", "startTimestamp").join("_")

    if REDIS.get(cache_key)
      puts "cached appointment #{slot.slice("locationId", "startTimestamp")}"
    else
      puts "sending message to #{ENV["TWILIO_TO"]} for #{slot.slice("locationId", "startTimestamp")}"
      start_time = Time.parse(slot["startTimestamp"])
      message = TWILIO.messages.create(
        from: ENV["TWILIO_FROM"],
        to: ENV["TWILIO_TO"],
        body: "Nexus appt in %{location} at %{time}! Log in at https://ttp.cbp.dhs.gov" % {
          location: LOCATIONS[slot["locationId"]],
          time: start_time.strftime("%A %B %d, %I:%M%p")
        }
      )
      puts "sent Message SID #{message.uri.delete_suffix(".json").split("/")[-1]}"

      expiry = start_time.to_i - Time.now.to_i
      REDIS.setex(cache_key, expiry, slot.to_s)
    end
  end
end
puts "done - exiting"