# Ends an inbound call that has rung for longer than its provider gives it. Nothing else
# moves a ringing call on when no end-of-ring arrives: the web keeps a ringing card, phones
# keep their ring, and the missed call is never recorded.
class Voice::RingingTimeoutService
  pattr_initialize [:call!]

  # Meta's carrier ring lasts up to about 60 s, so a call is never ended here while the
  # caller still hears it ring. A Twilio caller waits on hold until an agent joins; their
  # timeout is TWILIO_RING_TIMEOUT_SECONDS, see .ring_timeouts.
  RING_TIMEOUT_SECONDS = { 'whatsapp' => 60 }.freeze
  # A claim normally turns into a joined call within seconds; one still ringing this long
  # after it was made was abandoned (the agent's join failed or the tab closed)
  CLAIM_GRACE_SECONDS = 60
  # Twilio ends a call after 4 hours, so a Twilio call still ringing past that is a row
  # left behind, with no caller to move out
  TWILIO_MAX_CALL_AGE = 4.hours
  # A timeout attempt older than this is taken to have died, and another may start
  ATTEMPT_TTL_SECONDS = 120
  # Each Twilio request of an attempt gives up well inside its TTL, so the mark cannot run
  # out, and a claim succeed, while a stalled request still goes through
  TWILIO_REQUEST_TIMEOUT_SECONDS = 10
  # What a Twilio caller hears before the call ends: the <Say> voice and text per language
  TWILIO_TIMEOUT_SAY = {
    'de-DE' => ['Polly.Vicki-Neural', 'Leider ist gerade niemand erreichbar. Bitte rufen Sie später noch einmal an.'],
    'en-US' => ['Polly.Joanna-Neural', 'Sorry, nobody is available to take your call right now. Please call again later.']
  }.freeze

  def self.ring_timeouts = RING_TIMEOUT_SECONDS.merge('twilio' => twilio_ring_timeout)

  # A blank, zero or malformed value would end every Twilio call on the next sweep
  def self.twilio_ring_timeout
    seconds = Integer(ENV.fetch('TWILIO_RING_TIMEOUT_SECONDS', ''), 10, exception: false)
    seconds&.positive? ? seconds : 90
  end

  # Inbound calls still ringing past their provider's timeout. A WhatsApp call counts once
  # it rang phones, as the agents rung recorded on the call show, so one stays covered if
  # the account stops ringing phones meanwhile; a WhatsApp answer moves the call on as it
  # is claimed. A Twilio call counts whether or not it rang phones, since an account that
  # rings only browsers records no agents rung. An outbound call ends with the provider's
  # own word.
  def self.overdue
    ringing = Call.where(status: 'ringing', direction: :incoming)
    ringing.whatsapp.where(created_at: ...ring_timeouts['whatsapp'].seconds.ago).where("calls.ring_state ? 'ring_recipient_ids'")
           .or(ringing.twilio.where(created_at: TWILIO_MAX_CALL_AGE.ago...ring_timeouts['twilio'].seconds.ago))
  end

  # The call is marked as timing out under the row lock, which an agent's claim checks, so
  # a claim made from here on is refused, another sweep leaves the call alone, and the
  # provider's statuses for the hang-up wait while the mark is fresh. A Twilio caller is
  # moved out of the conference outside the lock, so the webhooks the move triggers do not
  # wait on it. The call is ended only once the caller is gone and it is still ringing;
  # otherwise this attempt's mark is cleared and the next sweep decides again. A hang-up
  # the mark held back left Twilio's final status on the call, so it counts as gone too.
  def perform
    return unless start_timeout

    # ponytail: Twilio callers nobody answers hear a message and are hung up, delete when Chatwoot ships a configurable no-answer fallback
    caller_gone = move_caller_out
    call.with_lock do
      next unless call.ring_state['timing_out_at'] == @attempt_at

      caller_gone ||= Voice::StatusUpdateService::TERMINAL_PROVIDER_STATUSES.include?(call.provider_status)
      if caller_gone && call.ringing?
        finalize
      else
        clear_timeout_mark
      end
    end
  end

  private

  def start_timeout
    call.with_lock do
      next false unless call.ringing? && call.incoming? && due? && !call.ring_timeout_in_progress?

      @attempt_at = Time.zone.now.to_i
      call.update_columns(ring_state: call.ring_state.merge('timing_out_at' => @attempt_at)) # rubocop:disable Rails/SkipsModelValidations
      true
    end
  end

  # Rung past its provider's timeout, and either unclaimed or claimed long enough ago that
  # the join was abandoned
  def due?
    timeout = self.class.ring_timeouts[call.provider]
    return false unless timeout.present? && call.created_at < timeout.seconds.ago
    return true if call.accepted_by_agent_id.nil?

    (call.ring_state['claimed_at'] || call.created_at.to_i) < CLAIM_GRACE_SECONDS.seconds.ago.to_i
  end

  def clear_timeout_mark
    call.update_columns(ring_state: call.ring_state.except('timing_out_at')) # rubocop:disable Rails/SkipsModelValidations
  end

  # Whether the caller is gone. Meta has already given up on a WhatsApp call. A Twilio
  # caller still waiting in the conference is redirected to a short message and hung up; a
  # call Twilio says is no longer in progress (21220) or does not know (404) was already
  # hung up. Any other failure leaves the call ringing for the next sweep.
  def move_caller_out
    return true unless call.twilio?
    return false if agent_on_call?

    twilio_client.calls(call.provider_call_id).update(twiml: timeout_twiml)
    true
  rescue StandardError => e
    return true if e.is_a?(Twilio::REST::RestError) && (e.code == 21_220 || e.status_code == 404)

    Rails.logger.error("[VOICE] ring timeout call #{call.id}: could not move the caller out: #{e.class}: #{e.message}")
    false
  end

  # Only an agent's join webhook moves a Twilio call on from ringing, so a lost one leaves a
  # call an agent is talking on looking unanswered. Twilio's conference decides: a caller
  # waiting alone is in one that has not started. When Twilio cannot say, the call is left
  # ringing and the next sweep asks again.
  def agent_on_call?
    Voice::Provider::Twilio::ConferenceService.new(call: call, client: twilio_client).agents_remain?(leaving_call_sid: nil)
  rescue StandardError => e
    Rails.logger.error("[VOICE] ring timeout call #{call.id}: could not look up the conference: #{e.class}: #{e.message}")
    true
  end

  # The channel's own client, so the install's Twilio region applies
  def twilio_client
    @twilio_client ||= call.inbox.channel.client.tap do |client|
      client.http_client = Twilio::HTTP::Client.new(timeout: TWILIO_REQUEST_TIMEOUT_SECONDS)
    end
  end

  def timeout_twiml
    language = call.account.locale.to_s.start_with?('de') ? 'de-DE' : 'en-US'
    voice, text = TWILIO_TIMEOUT_SAY[language]

    Twilio::TwiML::VoiceResponse.new do |response|
      response.say(message: text, language: language, voice: voice)
      response.hangup
    end.to_s
  end

  def finalize
    call.update!(status: 'no_answer', end_reason: 'ring_timeout', meta: (call.meta || {}).merge('ended_at' => Time.zone.now.to_i))
    Voice::CallMessageBuilder.new(call).update_status!(status: 'no_answer')
    call.conversation.update!(
      additional_attributes: (call.conversation.additional_attributes || {}).merge('call_status' => call.display_status)
    )
    call.broadcast_voice_call_event(:ended, status: call.display_status)
  end
end
