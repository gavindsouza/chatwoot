# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::RingingTimeoutService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account, phone_number: '+15551239999') }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call) { create(:call, conversation: conversation, provider: :whatsapp, status: 'ringing') }
  let(:twilio_call) { instance_double(Twilio::REST::Api::V2010::AccountContext::CallContext, update: nil) }
  let(:twilio_client) { instance_double(Twilio::REST::Client, calls: twilio_call) }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(8)}"))
    account.enable_features!('mobile_voice_push')
    allow(Twilio::REST::Client).to receive(:new).and_return(twilio_client)
    allow(ActionCable.server).to receive(:broadcast)
    call.update!(message: Voice::CallMessageBuilder.new(call).perform!)
  end

  describe '.overdue' do
    def ringing(provider, age)
      create(:call, conversation: create(:conversation, account: account, inbox: inbox), provider: provider, status: 'ringing',
                    created_at: age.ago, ring_state: { 'ring_recipient_ids' => [] })
    end

    it 'ignores a call that rang no phones, with no agents recorded for it' do
      ringing(:whatsapp, 5.minutes).update!(ring_state: {})

      expect(described_class.overdue).to be_empty
    end

    it 'returns WhatsApp calls ringing for more than 60 s and Twilio calls ringing for more than 90 s' do
      overdue_whatsapp = ringing(:whatsapp, 61.seconds)
      overdue_twilio = ringing(:twilio, 91.seconds)
      ringing(:whatsapp, 59.seconds)
      ringing(:twilio, 89.seconds)

      expect(described_class.overdue).to contain_exactly(overdue_whatsapp, overdue_twilio)
    end

    it 'returns a Twilio call that rang only browsers, with no agents recorded for it' do
      overdue = ringing(:twilio, 91.seconds)
      overdue.update!(ring_state: {})

      expect(described_class.overdue).to contain_exactly(overdue)
    end

    it 'times Twilio calls out after TWILIO_RING_TIMEOUT_SECONDS' do
      overdue = ringing(:twilio, 31.seconds)
      ringing(:twilio, 29.seconds)

      with_modified_env(TWILIO_RING_TIMEOUT_SECONDS: '30') do
        expect(described_class.overdue).to contain_exactly(overdue)
      end
    end

    it 'keeps the 90 s default when TWILIO_RING_TIMEOUT_SECONDS is blank, zero or malformed' do
      ringing(:twilio, 89.seconds)

      ['', '0', '1m30'].each do |value|
        with_modified_env(TWILIO_RING_TIMEOUT_SECONDS: value) { expect(described_class.overdue).to be_empty }
      end
    end

    it 'reads TWILIO_RING_TIMEOUT_SECONDS as decimal, not octal' do
      with_modified_env(TWILIO_RING_TIMEOUT_SECONDS: '060') { expect(described_class.twilio_ring_timeout).to eq(60) }
    end

    it 'leaves a Twilio call older than the longest call Twilio allows, which has no caller left' do
      ringing(:twilio, 5.hours)

      expect(described_class.overdue).to be_empty
    end

    it 'ignores calls that are no longer ringing' do
      old = ringing(:whatsapp, 5.minutes)
      old.update!(status: 'in_progress')

      expect(described_class.overdue).to be_empty
    end

    it 'ignores outbound calls, which end with the provider' do
      ringing(:whatsapp, 5.minutes).update!(direction: :outgoing)

      expect(described_class.overdue).to be_empty
    end

    it 'still returns a call that rang phones after the account stopped ringing them' do
      overdue = ringing(:whatsapp, 5.minutes)
      account.disable_features!('mobile_voice_push')

      expect(described_class.overdue).to contain_exactly(overdue)
    end
  end

  describe '#perform' do
    before { call.update!(created_at: 61.seconds.ago) }

    it 'ends the call as missed' do
      described_class.new(call: call).perform

      call.reload
      expect(call.status).to eq('no_answer')
      expect(call.end_reason).to eq('ring_timeout')
      expect(call.meta['ended_at']).to be_present
    end

    it 'updates the call message and the conversation the way a provider hang-up does' do
      described_class.new(call: call).perform

      expect(call.reload.message.content_attributes.dig('data', 'status')).to eq('no-answer')
      expect(conversation.reload.additional_attributes['call_status']).to eq('no-answer')
    end

    it 'broadcasts voice_call.ended to the account' do
      described_class.new(call: call).perform

      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}", hash_including(event: 'voice_call.ended', data: hash_including(id: call.id, status: 'no-answer'))
      )
    end

    it 'does not end a call answered before the sweep reached it' do
      call.update!(status: 'in_progress', accepted_by_agent: create(:user, account: account))

      described_class.new(call: call).perform

      expect(call.reload.status).to eq('in_progress')
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it 'leaves a call alone while another sweep is hanging it up' do
      call.update!(ring_state: { 'timing_out_at' => 10.seconds.ago.to_i })

      described_class.new(call: call).perform

      expect(call.reload.status).to eq('ringing')
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it 'takes over from a sweep that died long ago' do
      call.update!(ring_state: { 'timing_out_at' => 5.minutes.ago.to_i })

      described_class.new(call: call).perform

      expect(call.reload.status).to eq('no_answer')
    end

    it 'does not touch Twilio for a WhatsApp call' do
      described_class.new(call: call).perform

      expect(Twilio::REST::Client).not_to have_received(:new)
    end

    context 'with a Twilio call' do
      # A caller waiting alone is in a conference that has not started
      let(:conferences) { instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceList) }

      before do
        call.update!(provider: :twilio, created_at: 91.seconds.ago)
        call.merge_meta!('conference_sid' => call.default_conference_sid)
        allow(twilio_client).to receive(:http_client=)
        allow(twilio_client).to receive(:conferences).with(no_args).and_return(conferences)
        allow(conferences).to receive(:list).with(friendly_name: call.default_conference_sid, status: 'in-progress').and_return([])
      end

      def twilio_error(status, code)
        Twilio::REST::RestError.new('Unable to update record', Twilio::Response.new(status, { code: code, message: 'error' }.to_json))
      end

      def in_conference(*labels)
        conference = instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceContext)
        participants = labels.map do |label|
          instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceContext::ParticipantInstance, label: label, call_sid: "CA-#{label}")
        end
        allow(conferences).to receive(:list).and_return([instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceInstance, sid: 'CF1')])
        allow(twilio_client).to receive(:conferences).with('CF1').and_return(conference)
        allow(conference).to receive(:participants).and_return(
          instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceContext::ParticipantList, list: participants)
        )
      end

      it 'moves the caller out of the conference to a short message, then hangs up' do
        described_class.new(call: call).perform

        expect(twilio_client).to have_received(:calls).with(call.provider_call_id)
        expect(twilio_call).to have_received(:update).with(
          twiml: a_string_including('voice="Polly.Joanna-Neural"', 'language="en-US"').and(match(%r{Please call again later\.</Say>\s*<Hangup/>}))
        )
      end

      it "uses one client of the channel's, whose requests give up well before the attempt's mark runs out" do
        described_class.new(call: call).perform

        expect(Twilio::REST::Client).to have_received(:new).once
        expect(twilio_client).to have_received(:http_client=).with(having_attributes(timeout: 10)).once
      end

      it 'leaves the caller with an agent Twilio has in the conference, whose join was never reported' do
        agent = create(:user, account: account)
        travel_to(61.seconds.ago) do
          Voice::Provider::Twilio::ConferenceService.new(call: Call.find(call.id)).mark_agent_joined(user: agent, attempt: 'att-1')
          Call.find(call.id).open_agent_leg!('CA-agent', attempt: 'att-1')
        end
        in_conference('contact', "agent-#{agent.id}-account-#{account.id}")

        described_class.new(call: call).perform

        expect(twilio_call).not_to have_received(:update)
        expect(call.reload).to have_attributes(status: 'ringing', ring_state: hash_excluding('timing_out_at'))
        expect(ActionCable.server).not_to have_received(:broadcast)
      end

      it 'moves out a caller whose started conference has no agent left in it' do
        in_conference('contact')

        described_class.new(call: call).perform

        expect(twilio_call).to have_received(:update)
        expect(call.reload.status).to eq('no_answer')
      end

      it 'leaves the call ringing for the next sweep when Twilio cannot say who is in the conference' do
        allow(conferences).to receive(:list).and_raise(Twilio::REST::TwilioError, 'Net::ReadTimeout')

        described_class.new(call: call).perform

        expect(twilio_call).not_to have_received(:update)
        expect(call.reload).to have_attributes(status: 'ringing', ring_state: hash_excluding('timing_out_at'))
      end

      it 'speaks German on a German account' do
        account.update!(locale: 'de')

        described_class.new(call: call).perform

        expect(twilio_call).to have_received(:update).with(
          twiml: a_string_including('voice="Polly.Vicki-Neural"', 'language="de-DE"')
            .and(match(%r{Bitte rufen Sie später noch einmal an\.</Say>\s*<Hangup/>}))
        )
      end

      it 'ends the call as missed, with its message, conversation and ringing cards' do
        described_class.new(call: call).perform

        expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'ring_timeout')
        expect(call.message.content_attributes.dig('data', 'status')).to eq('no-answer')
        expect(conversation.reload.additional_attributes['call_status']).to eq('no-answer')
        expect(ActionCable.server).to have_received(:broadcast).with(
          "account_#{account.id}", hash_including(event: 'voice_call.ended', data: hash_including(id: call.id, status: 'no-answer'))
        )
      end

      it 'leaves a call younger than its timeout alone' do
        call.update!(created_at: 89.seconds.ago)

        described_class.new(call: call).perform

        expect(call.reload.status).to eq('ringing')
        expect(twilio_call).not_to have_received(:update)
      end

      it 'times out after TWILIO_RING_TIMEOUT_SECONDS' do
        call.update!(created_at: 31.seconds.ago)

        with_modified_env(TWILIO_RING_TIMEOUT_SECONDS: '30') { described_class.new(call: call).perform }

        expect(call.reload.status).to eq('no_answer')
      end

      it 'never moves out a caller an agent claimed before the sweep reached the call' do
        stale = Call.find(call.id)
        Voice::Provider::Twilio::ConferenceService.new(call: call).mark_agent_joined(user: create(:user, account: account))

        described_class.new(call: stale).perform

        expect(twilio_call).not_to have_received(:update)
        expect(call.reload).to have_attributes(status: 'ringing', ring_state: hash_excluding('timing_out_at'))
        expect(ActionCable.server).not_to have_received(:broadcast)
      end

      it 'moves out the caller of a claim whose join was abandoned' do
        call.update!(accepted_by_agent: create(:user, account: account), ring_state: { 'claimed_at' => 61.seconds.ago.to_i })

        described_class.new(call: call).perform

        expect(twilio_call).to have_received(:update)
        expect(call.reload.status).to eq('no_answer')
      end

      it 'refuses a claim while the caller is being moved out, and still ends the call' do
        agent = create(:user, account: account)
        refused = false
        allow(twilio_call).to receive(:update) do
          Voice::Provider::Twilio::ConferenceService.new(call: Call.find(call.id)).mark_agent_joined(user: agent)
        rescue Voice::CallErrors::CallAlreadyEnded
          refused = true
        end

        described_class.new(call: call).perform

        expect(refused).to be(true)
        expect(call.reload).to have_attributes(status: 'no_answer', accepted_by_agent_id: nil)
      end

      it 'keeps an answer that lands while the caller is being moved out, for the leave to complete' do
        agent = create(:user, account: account)
        allow(twilio_call).to receive(:update) do
          Voice::Conference::Manager.new(call: Call.find(call.id), event: 'join', participant_label: "agent-#{agent.id}-account-#{account.id}",
                                         participant_call_sid: 'CA-agent').process
        end

        described_class.new(call: call).perform

        expect(call.reload).to have_attributes(status: 'in_progress', end_reason: nil, ring_state: hash_excluding('timing_out_at'))
        expect(ActionCable.server).not_to have_received(:broadcast).with(anything, hash_including(event: 'voice_call.ended'))
      end

      it "records the timeout, not the caller's leave and hang-up the move triggers" do
        allow(twilio_call).to receive(:update) do
          Voice::Conference::Manager.new(call: Call.find(call.id), event: 'leave', participant_label: 'contact',
                                         participant_call_sid: call.provider_call_id).process
          Voice::CallStatus::Manager.new(call: Call.find(call.id)).process_status_update('completed', timestamp: Time.zone.now.to_i)
        end

        described_class.new(call: call).perform

        expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'ring_timeout')
      end

      it 'sends one missed-call notice, whatever the webhooks for the move report after the call ended' do
        call.update!(ring_state: { 'ring_recipient_ids' => [] })
        leave_and_hang_up = lambda do
          Voice::Conference::Manager.new(call: Call.find(call.id), event: 'leave', participant_label: 'contact',
                                         participant_call_sid: call.provider_call_id).process
          Voice::StatusUpdateService.new(account: account, call_sid: call.provider_call_id, call_status: 'completed').perform
        end

        expect do
          described_class.new(call: call).perform
          leave_and_hang_up.call
        end.to have_enqueued_job(Voice::MissedCallNotificationJob).with(call.id).exactly(:once)
        expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'ring_timeout')
      end

      it 'leaves the call ringing for the next sweep when Twilio fails' do
        allow(twilio_call).to receive(:update).and_raise(twilio_error(503, 503))

        expect { described_class.new(call: call).perform }.not_to raise_error

        expect(call.reload.status).to eq('ringing')
        expect(call.ring_state).not_to have_key('timing_out_at')
        expect(ActionCable.server).not_to have_received(:broadcast)
      end

      it 'leaves the call ringing for the next sweep when Twilio cannot be reached' do
        allow(twilio_call).to receive(:update).and_raise(Twilio::REST::TwilioError, 'connection refused')

        described_class.new(call: call).perform

        expect(call.reload).to have_attributes(status: 'ringing', ring_state: hash_excluding('timing_out_at'))
      end

      it 'ends a call whose caller hung up while the move failed, though the hang-up was held back' do
        allow(twilio_call).to receive(:update) do
          Voice::Conference::Manager.new(call: Call.find(call.id), event: 'leave', participant_label: 'contact',
                                         participant_call_sid: call.provider_call_id).process
          Voice::StatusUpdateService.new(account: account, call_sid: call.provider_call_id, call_status: 'completed').perform
          raise Twilio::REST::TwilioError, 'Net::ReadTimeout'
        end

        described_class.new(call: call).perform

        expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'ring_timeout')
      end

      [[400, 21_220], [404, 20_404]].each do |status, code|
        it "ends a call Twilio answers #{code} for, whose caller already hung up" do
          allow(twilio_call).to receive(:update).and_raise(twilio_error(status, code))

          described_class.new(call: call).perform

          expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'ring_timeout')
        end
      end
    end

    it 'does not touch a call that was answered in the meantime' do
      call.update!(status: 'in_progress')

      described_class.new(call: call).perform

      expect(call.reload.status).to eq('in_progress')
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it 'leaves a late provider end-of-ring with nothing to change' do
      described_class.new(call: call).perform
      described_class.new(call: call).perform

      expect(call.reload.status).to eq('no_answer')
      expect(ActionCable.server).to have_received(:broadcast).once
    end
  end
end
