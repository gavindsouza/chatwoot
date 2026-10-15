import { ref } from 'vue';
import { mount } from '@vue/test-utils';
import FloatingCallWidget from '../FloatingCallWidget.vue';

const session = {};

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: 1 } }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      getConversationById: () => undefined,
      'inboxes/getInbox': () => undefined,
    },
  }),
}));
vi.mock('dashboard/composables/useCallSession', () => ({
  useCallSession: () => session,
}));
vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  setWhatsappCallMuted: vi.fn(),
}));
vi.mock('dashboard/api/channel/voice/twilioVoiceClient', () => ({
  default: { setMuted: vi.fn() },
}));

// jsdom has no media playback; the widget loops a ringtone through Audio.
function AudioStub() {
  return { play: () => Promise.resolve(), pause: () => {} };
}

// Stand-in for CallCard: one red button per card, emitting what CallCard emits.
const CallCardStub = {
  props: ['call', 'state'],
  emits: ['reject'],
  template: '<button class="red" @click="$emit(\'reject\')" />',
};

const ringing = (callSid, callDirection, provider = 'twilio') => ({
  callSid,
  callDirection,
  provider,
  callId: 7,
  conversationId: 1,
  inboxId: 2,
});

const pressRed = calls => {
  session.incomingCalls = ref(calls);
  const wrapper = mount(FloatingCallWidget, {
    global: { stubs: { CallCard: CallCardStub } },
  });
  return wrapper.findAll('button.red');
};

describe('FloatingCallWidget red button', () => {
  beforeEach(() => {
    vi.stubGlobal('Audio', AudioStub);
    Object.assign(session, {
      activeCall: ref(null),
      hasActiveCall: ref(false),
      isJoining: ref(false),
      formattedCallDuration: ref('00:00'),
      joinCall: vi.fn(),
      endCall: vi.fn(),
      rejectIncomingCall: vi.fn(),
      dismissCall: vi.fn(),
    });
  });

  it.each(['twilio', 'whatsapp'])(
    'only dismisses a ringing incoming %s call for this agent',
    provider => {
      const [red] = pressRed([ringing('CA1', 'inbound', provider)]);
      red.trigger('click');

      expect(session.dismissCall).toHaveBeenCalledWith('CA1');
      expect(session.rejectIncomingCall).not.toHaveBeenCalled();
    }
  );

  it('only dismisses a stacked incoming call', () => {
    // The first call is the main card; the second is stacked above it.
    const [stacked] = pressRed([
      ringing('CA1', 'inbound'),
      ringing('CA2', 'inbound'),
    ]);
    stacked.trigger('click');

    expect(session.dismissCall).toHaveBeenCalledWith('CA2');
    expect(session.rejectIncomingCall).not.toHaveBeenCalled();
  });

  it.each(['twilio', 'whatsapp'])(
    'still ends one’s own ringing outbound %s call',
    provider => {
      const [red] = pressRed([ringing('CA1', 'outbound', provider)]);
      red.trigger('click');

      expect(session.rejectIncomingCall).toHaveBeenCalledWith('CA1');
      expect(session.dismissCall).not.toHaveBeenCalled();
    }
  );
});
