# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::RingingTimeoutJob do
  let(:account) { create(:account) }
  let(:service) { instance_double(Voice::RingingTimeoutService, perform: nil) }

  before do
    account.enable_features!('mobile_voice_push')
    allow(Voice::RingingTimeoutService).to receive(:new).and_return(service)
  end

  it 'runs on the scheduled jobs queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('scheduled_jobs')
  end

  it 'ends every overdue ringing call and leaves the rest alone' do
    rang = { 'ring_recipient_ids' => [] }
    overdue = create(:call, conversation: create(:conversation, account: account), provider: :whatsapp, created_at: 2.minutes.ago,
                            ring_state: rang)
    create(:call, conversation: create(:conversation, account: account), provider: :whatsapp, created_at: 10.seconds.ago, ring_state: rang)

    described_class.perform_now

    expect(Voice::RingingTimeoutService).to have_received(:new).once.with(call: overdue)
    expect(service).to have_received(:perform).once
  end

  it 'goes on to the other overdue calls when one cannot be ended' do
    rang = { 'ring_recipient_ids' => [] }
    calls = Array.new(2) do
      create(:call, conversation: create(:conversation, account: account), provider: :whatsapp, created_at: 2.minutes.ago, ring_state: rang)
    end
    allow(service).to receive(:perform).and_invoke(-> { raise ActiveRecord::StatementInvalid, 'boom' }, -> {})

    expect { described_class.perform_now }.not_to raise_error

    calls.each { |call| expect(Voice::RingingTimeoutService).to have_received(:new).with(call: call) }
    expect(service).to have_received(:perform).twice
  end
end
