import { createPinia, setActivePinia } from 'pinia';
import { useCallsStore } from 'dashboard/stores/calls';
import {
  CONTENT_TYPES,
  VOICE_CALL_STATUS,
} from 'dashboard/components-next/message/constants';
import {
  CALL_PAUSE_MINUTES_KEY,
  RECEIVE_CALLS_KEY,
  handleVoiceCallCreated,
  markCallDismissed,
  markCallEnded,
  offerRingingCalls,
  writeVoiceSetting,
} from '../voice';

vi.mock('dashboard/api/channel/voice/twilioVoiceClient', () => ({
  default: { endClientCall: vi.fn() },
}));
vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  cleanupWhatsappSession: vi.fn(),
}));

const AGENT_ID = 7;
const PAUSE_MS = 2 * 60 * 1000;

const callMessage = (callSid, direction = 'incoming') => ({
  content_type: CONTENT_TYPES.VOICE_CALL,
  conversation_id: 1,
  inbox_id: 1,
  sender: { id: direction === 'outgoing' ? AGENT_ID : 99 },
  call: {
    provider_call_id: callSid,
    provider: 'twilio',
    status: VOICE_CALL_STATUS.RINGING,
    direction,
  },
});

describe('ringing in this browser (Receive calls / Pause after a call)', () => {
  let callsStore;
  const offer = (callSid, direction) =>
    handleVoiceCallCreated(callMessage(callSid, direction), AGENT_ID, 'online');
  const isShown = callSid => callsStore.calls.some(c => c.callSid === callSid);

  beforeEach(() => {
    vi.useFakeTimers();
    localStorage.clear();
    setActivePinia(createPinia());
    callsStore = useCallsStore();
  });

  afterEach(() => vi.useRealTimers());

  it('does not ring inbound calls while Receive calls is off (the default)', () => {
    offer('CA-off');
    offer('CA-outbound', 'outgoing');

    expect(isShown('CA-off')).toBe(false);
    expect(isShown('CA-outbound')).toBe(true);
  });

  it('rings inbound calls once Receive calls is on', () => {
    writeVoiceSetting(RECEIVE_CALLS_KEY, true);
    offer('CA-on');

    expect(isShown('CA-on')).toBe(true);
  });

  it('holds a call during the pause after a call and offers it when the pause ends', () => {
    writeVoiceSetting(RECEIVE_CALLS_KEY, true);
    markCallEnded();
    offer('CA-held');

    vi.advanceTimersByTime(PAUSE_MS - 1);
    expect(isShown('CA-held')).toBe(false);

    vi.advanceTimersByTime(1);
    expect(isShown('CA-held')).toBe(true);
  });

  it('releases a held call soon after the pause is shortened', () => {
    writeVoiceSetting(RECEIVE_CALLS_KEY, true);
    writeVoiceSetting(CALL_PAUSE_MINUTES_KEY, 5);
    markCallEnded();
    offer('CA-held');

    writeVoiceSetting(CALL_PAUSE_MINUTES_KEY, 0);
    vi.advanceTimersByTime(5000);
    expect(isShown('CA-held')).toBe(true);
  });

  it('offers a call that rang while Receive calls was off once it is turned on', () => {
    const store = {
      getters: {
        getAllConversations: [{ messages: [callMessage('CA-rang')] }],
        getCurrentUserID: AGENT_ID,
        getCurrentUserAvailability: 'online',
      },
    };
    offerRingingCalls(store);
    expect(isShown('CA-rang')).toBe(false);

    writeVoiceSetting(RECEIVE_CALLS_KEY, true);
    offerRingingCalls(store);
    expect(isShown('CA-rang')).toBe(true);
  });

  it('holds a call that stacked up during the call until the pause ends', () => {
    writeVoiceSetting(RECEIVE_CALLS_KEY, true);
    offer('CA-active');
    callsStore.setCallActive('CA-active');
    offer('CA-stacked');
    callsStore.clearActiveCall();
    markCallEnded();
    expect(isShown('CA-stacked')).toBe(false);

    vi.advanceTimersByTime(PAUSE_MS);
    expect(isShown('CA-stacked')).toBe(true);
  });

  it('does not offer a held call that ended or was taken during the pause', () => {
    writeVoiceSetting(RECEIVE_CALLS_KEY, true);
    markCallEnded();
    offer('CA-gone');
    // what voice_call.ended / voice_call.accepted / a terminal update do
    markCallDismissed('CA-gone');

    vi.advanceTimersByTime(PAUSE_MS);
    expect(isShown('CA-gone')).toBe(false);
  });
});
