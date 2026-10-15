import {
  CONTENT_TYPES,
  VOICE_CALL_STATUS,
} from 'dashboard/components-next/message/constants';
import { MESSAGE_TYPE } from 'shared/constants/messages';
import { useCallsStore } from 'dashboard/stores/calls';
import types from 'dashboard/store/mutation-types';

export const TERMINAL_STATUSES = [
  'completed',
  'busy',
  'failed',
  'rejected',
  'no-answer',
  'canceled',
  'missed',
  'ended',
];

// A message.created for a ringing call is queued through ActionCableBroadcastJob and can
// be delivered after the call has already been accepted/ended via a synchronous broadcast.
// Track dismissed call sids at module scope so that late, stale "ringing" snapshot doesn't
// resurrect a card every caller of handleVoiceCallCreated (hydration and real-time alike)
// has already cleared.
const dismissedCallSids = new Set();
export const markCallDismissed = callSid => {
  if (callSid) dismissedCallSids.add(callSid);
};

// Which Twilio call (if any) this tab is actively joining/owns. Must be set
// synchronously BEFORE the join API call — mirrors useWhatsappCallSession's
// activeCallId — so the account-wide voice_call.accepted broadcast (which can
// arrive before the join promise resolves) doesn't mistake this tab's own
// call for a sibling tab's and tear it down mid-join.
let localCallSid = null;
export const markLocalCall = callSid => {
  localCallSid = callSid || null;
};
export const isLocalCall = callSid =>
  !!callSid && localCallSid != null && callSid === localCallSid;
export const clearLocalCall = callSid => {
  if (localCallSid === callSid) localCallSid = null;
};

export const isInbound = direction => direction === 'inbound';

const isVoiceCallMessage = message => {
  return CONTENT_TYPES.VOICE_CALL === message?.content_type;
};

const shouldSkipCall = (callDirection, senderId, currentUserId) => {
  return callDirection === 'outbound' && senderId !== currentUserId;
};

const extractAssigneeId = conversation => {
  return conversation?.assignee_id || conversation?.meta?.assignee?.id || null;
};

const isAssignedToAnotherAgent = (assigneeId, currentUserId) => {
  if (currentUserId == null) return false;
  return !!assigneeId && assigneeId !== currentUserId;
};

const shouldShowCall = ({
  callDirection,
  senderId,
  assigneeId,
  currentUserId,
}) => {
  if (shouldSkipCall(callDirection, senderId, currentUserId)) return false;
  // Outbound calls are scoped to the initiator via shouldSkipCall; the
  // conversation may be auto-assigned to a different agent on creation, so
  // skip the assignee filter for outbound to avoid hiding the caller's own widget.
  if (callDirection === 'outbound') return true;
  return !isAssignedToAnotherAgent(assigneeId, currentUserId);
};

// ponytail: per-browser "Receive calls" (default off) and "Pause after a call"
// (default 2 min) from the status menu, delete when Chatwoot ships server-side,
// admin-configurable call availability (SwitchUp req 1, 2.4, 2.5).
// Read on every decision, so a change applies at once and in every tab.
export const RECEIVE_CALLS_KEY = 'voiceReceiveCalls';
export const CALL_PAUSE_MINUTES_KEY = 'voiceCallPauseMinutes';
const CALL_ENDED_AT_KEY = 'voiceCallEndedAt';

export const readVoiceSetting = (key, fallback) => {
  try {
    const value = JSON.parse(window.localStorage.getItem(key));
    return typeof value === typeof fallback ? value : fallback;
  } catch {
    return fallback;
  }
};
export const writeVoiceSetting = (key, value) => {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // private mode: the defaults stay in force
  }
};
const callPauseLeft = () =>
  readVoiceSetting(CALL_ENDED_AT_KEY, 0) +
  readVoiceSetting(CALL_PAUSE_MINUTES_KEY, 2) * 60 * 1000 -
  Date.now();
// Runs `offer` once the pause is over (it can restart meanwhile), unless the
// call was taken or ended in the meantime. Looks again every few seconds so a
// shortened pause releases the call without waiting out the old one.
const offerAfterPause = (callSid, offer) => {
  const pauseLeft = callPauseLeft();
  if (pauseLeft > 0) {
    setTimeout(
      () => offerAfterPause(callSid, offer),
      Math.min(pauseLeft, 5000)
    );
  } else if (!dismissedCallSids.has(callSid)) {
    offer();
  }
};
export const markCallEnded = () => {
  writeVoiceSetting(CALL_ENDED_AT_KEY, Date.now());
  if (callPauseLeft() <= 0) return;
  // Calls that stacked up silently during the call would ring the moment it
  // ends, so they wait for the pause too, except the one the agent is
  // switching to (FloatingCallWidget marks it local before hanging up).
  const callsStore = useCallsStore();
  callsStore.incomingCalls
    .filter(call => isInbound(call.callDirection) && !isLocalCall(call.callSid))
    .forEach(call => {
      callsStore.dismissCall(call.callSid);
      offerAfterPause(call.callSid, () => {
        if (readVoiceSetting(RECEIVE_CALLS_KEY, false)) {
          callsStore.addCall(call);
        }
      });
    });
};

// Offline/busy agents shouldn't get a ringing popup for inbound calls, but
// outbound calls always belong to the initiator regardless of their status,
// and existing (already-surfaced) calls keep going so a status change
// mid-call doesn't yank away an active widget.
export const shouldRingInbound = (callDirection, currentUserAvailability) => {
  if (callDirection === 'outbound') return true;
  return (
    currentUserAvailability === 'online' &&
    readVoiceSetting(RECEIVE_CALLS_KEY, false) &&
    callPauseLeft() <= 0
  );
};

function extractCallerSnapshot(message) {
  // Snapshot caller info from the message at add-time so the widget can keep
  // rendering it after the user navigates away from a conversation list that
  // had the conversation hydrated (and Vuex evicts it from the store).
  // Only incoming messages carry the contact as the sender; on outbound calls
  // the sender is the initiating agent, so skip the snapshot and let the widget
  // fall back to the conversation's contact (conversation.meta.sender).
  if (message?.message_type !== MESSAGE_TYPE.INCOMING) return null;
  const sender = message?.sender;
  if (!sender) return null;
  return {
    name: sender.name,
    phone: sender.phone_number,
    avatar: sender.avatar || sender.thumbnail,
    additionalAttributes: sender.additional_attributes || {},
  };
}

function extractCallData(message) {
  const call = message?.call || {};
  return {
    callSid: call.provider_call_id,
    callId: call.id,
    provider: call.provider,
    status: call.status,
    callDirection: call.direction === 'outgoing' ? 'outbound' : 'inbound',
    conversationId: message?.conversation_id,
    inboxId: message?.inbox_id ?? message?.conversation?.inbox_id,
    assigneeId: extractAssigneeId(message?.conversation),
    senderId: message?.sender?.id,
    caller: extractCallerSnapshot(message),
  };
}

export function handleVoiceCallCreated(
  message,
  currentUserId,
  currentUserAvailability
) {
  if (!isVoiceCallMessage(message)) return;

  const {
    callSid,
    callId,
    provider,
    status,
    callDirection,
    conversationId,
    inboxId,
    assigneeId,
    senderId,
  } = extractCallData(message);

  if (callSid && dismissedCallSids.has(callSid)) return;

  // A voice_call message can be created already terminal when the caller hangs
  // up before connect. Only ring while the call is actually ringing; mirrors the
  // guard in seedCallsFromHydratedMessages.
  if (status !== VOICE_CALL_STATUS.RINGING) return;

  if (
    !shouldShowCall({
      callDirection,
      senderId,
      assigneeId,
      currentUserId,
    })
  ) {
    return;
  }

  if (!shouldRingInbound(callDirection, currentUserAvailability)) {
    // ponytail: a call held back by the pause is offered when the pause ends,
    // delete when Chatwoot ships server-side call availability.
    if (callPauseLeft() > 0) {
      offerAfterPause(callSid, () =>
        handleVoiceCallCreated(message, currentUserId, currentUserAvailability)
      );
    }
    return;
  }

  const callsStore = useCallsStore();
  callsStore.addCall({
    callSid,
    callId,
    provider,
    conversationId,
    inboxId,
    callDirection,
    senderId,
    caller: extractCallerSnapshot(message),
  });
}

// Turning Receive calls on offers the calls that rang while it was off, the
// way the hydration seeding in useCallSession does on a refresh.
export const offerRingingCalls = ({ getters }) =>
  (getters.getAllConversations || []).forEach(conversation =>
    (conversation.messages || []).forEach(message =>
      handleVoiceCallCreated(
        message,
        getters.getCurrentUserID,
        getters.getCurrentUserAvailability
      )
    )
  );

export function handleVoiceCallUpdated(
  commit,
  message,
  currentUserId,
  currentUserAvailability
) {
  if (!isVoiceCallMessage(message)) return;

  const {
    callSid,
    callId,
    provider,
    status,
    callDirection,
    conversationId,
    inboxId,
    assigneeId,
    senderId,
  } = extractCallData(message);

  const callsStore = useCallsStore();

  // Guard against a still-queued ringing message.created arriving after this
  // terminal update, same as the accepted/ended broadcast handlers.
  if (TERMINAL_STATUSES.includes(status)) markCallDismissed(callSid);

  callsStore.handleCallStatusChanged({ callSid, status, conversationId });

  commit(types.UPDATE_MESSAGE_CALL_STATUS, {
    conversationId,
    callStatus: status,
    callSid,
  });

  if (
    !shouldShowCall({
      callDirection,
      senderId,
      assigneeId,
      currentUserId,
    })
  ) {
    callsStore.removeCall(callSid);
    return;
  }

  if (status === 'ringing') {
    if (!shouldRingInbound(callDirection, currentUserAvailability)) return;

    callsStore.addCall({
      callSid,
      callId,
      provider,
      conversationId,
      inboxId,
      callDirection,
      senderId,
      caller: extractCallerSnapshot(message),
    });
  }
}

export function syncConversationCallVisibility(conversation, currentUserId) {
  const assigneeId = extractAssigneeId(conversation);
  if (!isAssignedToAnotherAgent(assigneeId, currentUserId)) return;

  // Outbound calls belong to the initiator regardless of who the conversation
  // is currently assigned to (auto-assignment may flip mid-call). Mirror
  // shouldShowCall's outbound exception so an in-progress outbound call isn't
  // ripped out from under the caller when the conversation reassigns.
  const callsStore = useCallsStore();
  const callsToRemove = callsStore.calls.filter(
    call =>
      call.conversationId === conversation.id &&
      !shouldShowCall({
        callDirection: call.callDirection,
        senderId: call.senderId,
        assigneeId,
        currentUserId,
      })
  );
  callsToRemove.forEach(call => callsStore.removeCall(call.callSid));
}
