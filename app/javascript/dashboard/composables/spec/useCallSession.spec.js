import { mount } from '@vue/test-utils';
import { setActivePinia, createPinia } from 'pinia';
import { useCallsStore } from 'dashboard/stores/calls';
import { useCallSession } from '../useCallSession';

vi.mock('vuex', () => ({
  useStore: () => ({ getters: { getAllConversations: [] } }),
}));
vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  useWhatsappCallSession: () => ({}),
  sendWhatsappTerminateBeacon: vi.fn(),
  cleanupWhatsappSession: vi.fn(),
}));
vi.mock('dashboard/api/channel/voice/twilioVoiceClient', () => ({
  default: {
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    endClientCall: vi.fn(),
  },
}));

const CHANNEL = 'cw-call-dismissed';

describe('useCallSession dismissal across tabs', () => {
  let session;
  let wrapper;
  let otherTab;

  beforeEach(() => {
    setActivePinia(createPinia());
    wrapper = mount({
      template: '<div />',
      setup() {
        session = useCallSession();
        return {};
      },
    });
    // The agent's other dashboard tab, as a second BroadcastChannel
    otherTab = new BroadcastChannel(CHANNEL);
  });

  afterEach(() => {
    otherTab.close();
    wrapper.unmount();
  });

  it('tells the other tabs a call was dismissed', async () => {
    const received = new Promise(resolve => {
      otherTab.onmessage = ({ data }) => resolve(data);
    });

    session.dismissCall('CA1');

    expect(await received).toBe('CA1');
  });

  it('drops a call another tab dismissed, unless this tab joined it', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({ callSid: 'CA1' });
    callsStore.addCall({ callSid: 'CA2' });
    callsStore.setCallActive('CA2');

    // Delivery is in order, so CA2 was already refused by the time CA1 is gone
    otherTab.postMessage('CA2');
    otherTab.postMessage('CA1');

    await vi.waitFor(() => {
      expect(callsStore.calls.map(c => c.callSid)).toEqual(['CA2']);
    });
  });
});
