import { nextTick, watch } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import TwilioVoiceClient from 'dashboard/api/channel/voice/twilioVoiceClient';
import { useCallsStore } from 'dashboard/stores/calls';
import {
  CALL_PAUSE_MINUTES_KEY,
  markCallEnded,
  writeVoiceSetting,
} from 'dashboard/helper/voice';
import FloatingCallWidget from '../FloatingCallWidget.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: 1 } }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('vuex', async importOriginal => ({
  ...(await importOriginal()),
  useStore: () => ({
    getters: {
      getConversationById: () => undefined,
      'inboxes/getInbox': () => undefined,
    },
  }),
}));
vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: { leaveConference: vi.fn(), joinConference: vi.fn() },
}));
vi.mock('dashboard/api/channel/voice/twilioVoiceClient', () => ({
  default: {
    initializeDevice: vi.fn(),
    joinClientCall: vi.fn(),
    endClientCall: vi.fn(),
    setMuted: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  },
}));
vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  useWhatsappCallSession: () => ({}),
  cleanupWhatsappSession: vi.fn(),
  sendWhatsappTerminateBeacon: vi.fn(),
  setWhatsappCallMuted: vi.fn(),
}));

const twilioCall = callSid => ({
  callSid,
  conversationId: 1,
  inboxId: 1,
  provider: 'twilio',
  callDirection: 'inbound',
});

describe('FloatingCallWidget', () => {
  it('keeps the stacked call the agent accepts out of the pause that hanging up starts', async () => {
    vi.stubGlobal(
      'Audio',
      vi.fn(() => ({ play: () => Promise.resolve(), pause: () => {} }))
    );
    VoiceAPI.leaveConference.mockResolvedValue({});
    VoiceAPI.joinConference.mockResolvedValue({ conference_sid: 'CF-B' });
    TwilioVoiceClient.initializeDevice.mockResolvedValue({});
    TwilioVoiceClient.joinClientCall.mockResolvedValue({});
    writeVoiceSetting(CALL_PAUSE_MINUTES_KEY, 2);

    setActivePinia(createPinia());
    const callsStore = useCallsStore();
    // Dashboard.vue's watcher, which runs between the hang-up and the join
    watch(
      () => callsStore.hasActiveCall,
      (active, wasActive) => wasActive && !active && markCallEnded()
    );
    callsStore.addCall(twilioCall('CA-A'));
    callsStore.addCall(twilioCall('CA-B'));
    callsStore.setCallActive('CA-A');

    const wrapper = mount(FloatingCallWidget, {
      global: {
        stubs: {
          CallCard: {
            props: ['call'],
            emits: ['accept'],
            template: '<i :id="call.callSid" @click="$emit(\'accept\')" />',
          },
        },
      },
    });
    await nextTick();
    await wrapper.find('#CA-B').trigger('click');
    await flushPromises();

    expect(TwilioVoiceClient.joinClientCall).toHaveBeenCalledOnce();
    expect(callsStore.calls).toMatchObject([
      { callSid: 'CA-B', isActive: true },
    ]);
    wrapper.unmount();
  });
});
