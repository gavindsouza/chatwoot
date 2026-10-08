require 'rails_helper'

describe Voice::Provider::Twilio::TokenService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:voice_channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:inbox) { voice_channel.inbox }

  let(:webhook_service) { instance_double(Twilio::VoiceWebhookSetupService, perform: true) }
  let(:voice_grant) { instance_double(Twilio::JWT::AccessToken::VoiceGrant) }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new).and_return(webhook_service)
    allow(Twilio::JWT::AccessToken::VoiceGrant).to receive(:new).and_return(voice_grant)
    allow(voice_grant).to receive(:outgoing_application_sid=)
    allow(voice_grant).to receive(:outgoing_application_params=)
    allow(voice_grant).to receive(:incoming_allow=)
  end

  it 'returns a token payload with expected keys' do
    fake_token = instance_double(Twilio::JWT::AccessToken, to_jwt: 'jwt-token', add_grant: nil)
    allow(Twilio::JWT::AccessToken).to receive(:new).and_return(fake_token)

    payload = described_class.new(inbox: inbox, user: user, account: account).generate

    expect(payload[:token]).to eq('jwt-token')
    expect(payload[:identity]).to include("agent-#{user.id}")
    expect(payload[:inbox_id]).to eq(inbox.id)
    expect(payload[:account_id]).to eq(account.id)
    expect(payload[:voice_enabled]).to be true
    expect(payload[:twiml_endpoint]).to include(voice_channel.phone_number.delete_prefix('+'))
  end

  it 'routes the token and the browser Device to the configured Twilio region' do
    allow(Twilio).to receive_messages(region: 'ie1', edge: 'dublin')
    fake_token = instance_double(Twilio::JWT::AccessToken, to_jwt: 'jwt-token', add_grant: nil)
    allow(Twilio::JWT::AccessToken).to receive(:new).and_return(fake_token)

    payload = described_class.new(inbox: inbox, user: user, account: account).generate

    expect(Twilio::JWT::AccessToken).to have_received(:new).with(any_args, hash_including(region: 'ie1'))
    expect(payload[:edge]).to eq('dublin')
  end

  it 'keeps the token and the browser Device on the default region when none is configured' do
    allow(Twilio).to receive_messages(region: nil, edge: nil)
    fake_token = instance_double(Twilio::JWT::AccessToken, to_jwt: 'jwt-token', add_grant: nil)
    allow(Twilio::JWT::AccessToken).to receive(:new).and_return(fake_token)

    payload = described_class.new(inbox: inbox, user: user, account: account).generate

    expect(Twilio::JWT::AccessToken).to have_received(:new).with(any_args, hash_including(region: nil))
    expect(payload[:edge]).to be_nil
  end
end
