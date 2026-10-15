class Twilio::VoiceController < ApplicationController # rubocop:disable Metrics/ClassLength
  CONFERENCE_EVENT_PATTERNS = {
    /conference-start/i => 'start',
    /participant-join/i => 'join',
    /participant-leave/i => 'leave',
    /conference-end/i => 'end'
  }.freeze
  # The <Say> voice for each language, and what it says when the inbox has no out-of-office message
  OUT_OF_OFFICE_SAY = {
    'de-DE' => ['Polly.Vicki-Neural', 'Wir sind gerade nicht erreichbar. Bitte rufen Sie zu unseren Geschäftszeiten wieder an.'],
    'en-US' => ['Polly.Joanna-Neural', 'We are closed right now. Please call again during our business hours.']
  }.freeze

  before_action :set_inbox!

  def status
    Voice::StatusUpdateService.new(
      account: current_account,
      call_sid: twilio_call_sid,
      call_status: params[:CallStatus],
      payload: params.to_unsafe_h
    ).perform

    head :no_content
  end

  def call_twiml
    Rails.logger.info(
      "TWILIO_VOICE_TWIML account=#{current_account.id} call_sid=#{twilio_call_sid} from=#{twilio_from} direction=#{twilio_direction}"
    )

    return render xml: reject_twiml if reject_inbound?
    # ponytail: callers outside working hours hear the out-of-office message and are hung up, delete when Chatwoot ships working hours for voice
    return render xml: out_of_office_twiml if out_of_office_inbound?

    call = resolve_call
    # The leg was answered after the call ended (e.g. hangup raced the cancel); don't strand it in an empty conference.
    return render xml: hangup_twiml unless open_leg?(call)

    render xml: conference_twiml(call)
  end

  # The caller's wait audio: the greeting if asked for, then the ringback (a raw WAV as waitUrl would play once, then silence).
  def wait_twiml
    response = Twilio::TwiML::VoiceResponse.new.tap do |twiml|
      greet_caller(twiml) if params[:greet].present?
      twiml.play(url: ringback_url, loop: 0)
    end
    render xml: response.to_s
  end

  def conference_status
    event = mapped_conference_event
    if event.nil?
      Rails.logger.info(
        "TWILIO_VOICE_CONFERENCE_UNMAPPED_EVENT account=#{current_account.id} event=#{params[:StatusCallbackEvent]} call_sid=#{twilio_call_sid}"
      )
      return head :no_content
    end

    call = find_call_for_conference!(params[:FriendlyName], twilio_call_sid)
    persist_twilio_conference_sid!(call, params[:ConferenceSid])

    Voice::Conference::Manager.new(
      call: call,
      event: event,
      participant_label: participant_label,
      participant_call_sid: twilio_call_sid,
      leave_reason: params[:ReasonParticipantLeft]
    ).process

    head :no_content
  end

  # ponytail: ignore the unsigned callback, never fetch its RecordingUrl, delete when Chatwoot ships an install-wide recording off switch
  def recording_status
    head :no_content
  end

  private

  def twilio_call_sid = params[:CallSid]

  def twilio_from
    params[:From].to_s
  end

  def twilio_to
    params[:To]
  end

  def twilio_direction
    @twilio_direction ||= (params['Direction'] || params['CallDirection']).to_s
  end

  def mapped_conference_event
    event = params[:StatusCallbackEvent].to_s
    CONFERENCE_EVENT_PATTERNS.each do |pattern, mapped|
      return mapped if event.match?(pattern)
    end
    nil
  end

  def agent_leg?(from_number)
    from_number.start_with?('client:')
  end

  # A fresh contact-initiated leg on an inbox with inbound calls turned off.
  # Reject it so no conference, conversation, or Call row is created.
  def reject_inbound?
    twilio_direction == 'inbound' && !agent_leg?(twilio_from) && !inbox.channel.inbound_calls_enabled?
  end

  def reject_twiml
    Twilio::TwiML::VoiceResponse.new(&:reject).to_s
  end

  def hangup_twiml
    Twilio::TwiML::VoiceResponse.new(&:hangup).to_s
  end

  def out_of_office_inbound?
    twilio_direction == 'inbound' && !agent_leg?(twilio_from) && inbox.out_of_office?
  end

  # The call is ended in the transaction that creates it, so its message and conversation are
  # first broadcast with it already ended and no browser or phone rings; it stays in the call
  # history as missed
  def out_of_office_twiml
    ActiveRecord::Base.transaction { resolve_call.update!(status: 'no_answer', end_reason: 'out_of_office', ended_at: Time.zone.now.to_i) }
    language = inbox_account.locale.to_s.start_with?('de') ? 'de-DE' : 'en-US'
    voice, fallback = OUT_OF_OFFICE_SAY[language]
    text = ChatwootMarkdownRenderer.new(inbox.out_of_office_message.to_s).render_markdown_to_plain_text.squish.presence || fallback

    Twilio::TwiML::VoiceResponse.new do |response|
      response.say(message: text, language: language, voice: voice)
      response.hangup
    end.to_s
  end

  def resolve_call
    return find_call_for_agent if agent_leg?(twilio_from)

    case twilio_direction
    when 'inbound'
      Voice::InboundCallBuilder.perform!(
        inbox: inbox,
        call_sid: twilio_call_sid,
        caller: { source_ids: [twilio_from], contact_attributes: { name: twilio_from, phone_number: twilio_from } }
      )
    when 'outbound-api', 'outbound-dial'
      sync_outbound_leg(call_sid: twilio_call_sid, direction: twilio_direction)
    else
      raise ArgumentError, "Unsupported Twilio direction: #{twilio_direction}"
    end
  end

  # An agent's connection is recorded as on its way in, unless the call has ended
  def open_leg?(call) = agent_leg?(twilio_from) ? call.open_agent_leg!(twilio_call_sid, attempt: params[:attempt_id]) : !call.terminal?

  def find_call_for_agent
    sid = params[:call_sid].presence
    raise ArgumentError, 'call_sid is required for agent leg' if sid.blank?

    inbox_calls.find_by!(provider_call_id: sid)
  end

  def sync_outbound_leg(call_sid:, direction:)
    parent_sid = params['ParentCallSid'].presence
    lookup_sid = direction == 'outbound-dial' ? parent_sid || call_sid : call_sid
    call = inbox_calls.find_by!(provider_call_id: lookup_sid)

    call.merge_meta!('parent_call_sid' => parent_sid) if parent_sid.present? && call.parent_call_sid != parent_sid
    call
  end

  def inbox_calls
    Call.where(inbox_id: inbox.id, provider: :twilio)
  end

  def conference_twiml(call) # rubocop:disable Metrics/MethodLength
    conference_sid = ensure_conference_sid!(call)

    Twilio::TwiML::VoiceResponse.new.tap do |response|
      response.dial do |dial|
        dial.conference(
          conference_sid,
          beep: false,
          start_conference_on_enter: agent_leg?(twilio_from),
          end_conference_on_exit: false,
          record: call.recording_enabled? ? 'record-from-start' : 'do-not-record',
          recording_status_callback: recording_status_callback_url,
          recording_status_callback_event: 'completed',
          recording_status_callback_method: 'POST',
          status_callback: conference_status_callback_url,
          status_callback_event: 'start end join leave',
          status_callback_method: 'POST',
          participant_label: participant_label_for(twilio_from),
          **caller_wait_options(call)
        )
      end
    end.to_s
  end

  # ponytail: German ringback wait, no join beep and the inbox greeting for callers, delete when Chatwoot ships configurable voice inbox audio
  # The greeting is spoken from the wait doc so the caller is already in the conference while it plays; only inbound calls get it.
  def caller_wait_options(call)
    return {} if agent_leg?(twilio_from)

    phone_digits = inbox_channel.phone_number.delete_prefix('+')
    wait_url = Rails.application.routes.url_helpers.twilio_voice_wait_url(phone: phone_digits, greet: (1 if call.incoming?))
    { wait_url: wait_url, wait_method: 'GET' }
  end

  def ringback_url
    "#{Rails.application.routes.default_url_options[:host]}/audio/voice/ringback-de.wav"
  end

  def greet_caller(response)
    return unless inbox.greeting_enabled? && inbox.greeting_message.present?

    text = ChatwootMarkdownRenderer.new(inbox.greeting_message).render_markdown_to_plain_text.strip
    options = inbox_account.locale_de? ? { language: 'de-DE', voice: 'Polly.Vicki-Neural' } : {}
    response.say(message: text, **options)
  end

  def ensure_conference_sid!(call)
    return call.conference_sid if call.conference_sid.present?

    call.merge_meta!('conference_sid' => call.default_conference_sid)
    call.conference_sid
  end

  def participant_label_for(from_number)
    return from_number.delete_prefix('client:') if from_number.start_with?('client:')

    'contact'
  end

  def conference_status_callback_url
    phone_digits = inbox_channel.phone_number.delete_prefix('+')
    Rails.application.routes.url_helpers.twilio_voice_conference_status_url(phone: phone_digits)
  end

  def recording_status_callback_url
    phone_digits = inbox_channel.phone_number.delete_prefix('+')
    Rails.application.routes.url_helpers.twilio_voice_recording_status_url(phone: phone_digits)
  end

  def find_call_for_conference!(friendly_name, call_sid)
    name = friendly_name.to_s
    call = inbox_calls.by_conference_sid(name).first if name.present?
    call || inbox_calls.find_by!(provider_call_id: call_sid)
  end

  # Twilio's recording webhook only sends its internal ConferenceSid (CF...),
  # not our FriendlyName. Persist Twilio's id the first time we see it on a
  # conference event so the recording lookup can match later.
  def persist_twilio_conference_sid!(call, sid)
    return if sid.blank?
    return if call.twilio_conference_sid == sid

    call.merge_meta!('twilio_conference_sid' => sid)
  end

  def set_inbox!
    digits = params[:phone].to_s.gsub(/\D/, '')
    phone_number = "+#{digits}"
    channel = Channel::TwilioSms.find_by!(phone_number: phone_number)
    raise ActiveRecord::RecordNotFound, "Voice not enabled for #{phone_number}" unless channel.voice_enabled?

    @inbox = channel.inbox
  end

  def current_account
    @current_account ||= inbox_account
  end

  def participant_label
    params[:ParticipantLabel].to_s
  end

  attr_reader :inbox

  delegate :account, :channel, to: :inbox, prefix: true
end
