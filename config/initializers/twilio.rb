# Install-wide: routes the twilio-ruby REST clients of every Twilio channel (Voice, SMS, WhatsApp)
# to a non-US region, so all of them need credentials from that region. Unset keeps US1. The Voice
# access token and browser Device read the same values via Twilio.region / Twilio.edge.
region = ENV.fetch('TWILIO_REGION', '').strip.downcase.presence
edge = ENV.fetch('TWILIO_EDGE', '').strip.downcase.presence
# Without an edge Twilio sends a regional request to US1, where that region's credentials fail.
raise 'TWILIO_EDGE is required with TWILIO_REGION (e.g. ie1 needs dublin); unset TWILIO_REGION to stay on US1' if region && edge.nil?

Twilio.configure do |config|
  config.region = region
  config.edge = edge
end
