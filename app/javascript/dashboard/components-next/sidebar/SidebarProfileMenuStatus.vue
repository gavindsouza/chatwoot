<script setup>
import { computed, h, ref, watch } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import wootConstants from 'dashboard/constants/globals';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useImpersonation } from 'dashboard/composables/useImpersonation';
import { isVoiceCallEnabled } from 'dashboard/helper/inbox';
import {
  RECEIVE_CALLS_KEY,
  CALL_PAUSE_MINUTES_KEY,
  offerRingingCalls,
  readVoiceSetting,
  writeVoiceSetting,
} from 'dashboard/helper/voice';

import {
  DropdownContainer,
  DropdownBody,
  DropdownSection,
  DropdownItem,
} from 'next/dropdown-menu/base';
import Icon from 'next/icon/Icon.vue';
import Button from 'next/button/Button.vue';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import Select from 'dashboard/components-next/select/Select.vue';

const { t } = useI18n();
const store = useStore();
const currentUserAvailability = useMapGetter('getCurrentUserAvailability');
const currentAccountId = useMapGetter('getCurrentAccountId');
const currentUserAutoOffline = useMapGetter('getCurrentUserAutoOffline');

const { isImpersonating } = useImpersonation();

const { AVAILABILITY_STATUS_KEYS } = wootConstants;
const statusList = computed(() => {
  return [
    t('PROFILE_SETTINGS.FORM.AVAILABILITY.STATUS.ONLINE'),
    t('PROFILE_SETTINGS.FORM.AVAILABILITY.STATUS.BUSY'),
    t('PROFILE_SETTINGS.FORM.AVAILABILITY.STATUS.OFFLINE'),
  ];
});

const statusColors = ['bg-n-teal-9', 'bg-n-amber-9', 'bg-n-slate-9'];

const availabilityStatuses = computed(() => {
  return statusList.value.map((statusLabel, index) => ({
    label: statusLabel,
    value: AVAILABILITY_STATUS_KEYS[index],
    color: statusColors[index],
    icon: h('span', { class: [statusColors[index], 'size-[12px] rounded'] }),
    active: currentUserAvailability.value === AVAILABILITY_STATUS_KEYS[index],
  }));
});

const activeStatus = computed(() => {
  return availabilityStatuses.value.find(status => status.active);
});

const autoOfflineToggle = computed({
  get: () => currentUserAutoOffline.value,
  set: autoOffline => {
    store.dispatch('updateAutoOffline', {
      accountId: currentAccountId.value,
      autoOffline,
    });
  },
});

// ponytail: per-browser call settings (see helper/voice.js), delete when
// Chatwoot ships server-side call availability (SwitchUp req 1, 2.4, 2.5).
const inboxes = useMapGetter('inboxes/getInboxes');
const hasVoiceInbox = computed(() => inboxes.value.some(isVoiceCallEnabled));
const receiveCalls = ref(readVoiceSetting(RECEIVE_CALLS_KEY, false));
const callPauseMinutes = ref(readVoiceSetting(CALL_PAUSE_MINUTES_KEY, 2));
watch(receiveCalls, value => {
  writeVoiceSetting(RECEIVE_CALLS_KEY, value);
  if (value) offerRingingCalls(store);
});
watch(callPauseMinutes, value =>
  writeVoiceSetting(CALL_PAUSE_MINUTES_KEY, value)
);
const callPauseOptions = computed(() =>
  [0, 1, 2, 3, 5].map(minutes => ({
    value: minutes,
    label: minutes
      ? t('SIDEBAR.CALL_PAUSE.MINUTES', { count: minutes })
      : t('SIDEBAR.CALL_PAUSE.OFF'),
  }))
);

function changeAvailabilityStatus(availability) {
  if (isImpersonating.value) {
    useAlert(t('PROFILE_SETTINGS.FORM.AVAILABILITY.IMPERSONATING_ERROR'));
    return;
  }
  try {
    store.dispatch('updateAvailability', {
      availability,
      account_id: currentAccountId.value,
    });
  } catch (error) {
    useAlert(t('PROFILE_SETTINGS.FORM.AVAILABILITY.SET_AVAILABILITY_ERROR'));
  }
}
</script>

<template>
  <DropdownSection class="[&>ul]:overflow-visible">
    <div class="grid gap-0">
      <DropdownItem preserve-open class="gap-1">
        <div class="flex-grow flex items-center gap-1 min-w-0">
          {{ $t('SIDEBAR.SET_YOUR_AVAILABILITY') }}
        </div>
        <DropdownContainer class="shrink-0">
          <template #trigger="{ toggle }">
            <Button
              size="sm"
              color="slate"
              variant="faded"
              icon="i-lucide-chevron-down"
              trailing-icon
              @click="toggle"
            >
              <div class="flex gap-1 items-center min-w-0 text-sm">
                <div class="p-1 flex-shrink-0">
                  <div class="size-2 rounded-sm" :class="activeStatus.color" />
                </div>
                <span class="truncate max-w-[7rem]">
                  {{ activeStatus.label }}
                </span>
              </div>
            </Button>
          </template>
          <DropdownBody class="min-w-32 z-20">
            <DropdownItem
              v-for="status in availabilityStatuses"
              :key="status.value"
              :label="status.label"
              :icon="status.icon"
              class="cursor-pointer"
              @click="changeAvailabilityStatus(status.value)"
            />
          </DropdownBody>
        </DropdownContainer>
      </DropdownItem>
      <DropdownItem>
        <div class="flex-grow min-w-0">
          {{ $t('SIDEBAR.SET_AUTO_OFFLINE.TEXT') }}
          <Icon
            v-tooltip.top="$t('SIDEBAR.SET_AUTO_OFFLINE.INFO_SHORT')"
            icon="i-lucide-info"
            class="inline-block align-middle ms-1 size-4 text-n-slate-10"
          />
        </div>
        <ToggleSwitch v-model="autoOfflineToggle" />
      </DropdownItem>
      <template v-if="hasVoiceInbox">
        <DropdownItem preserve-open>
          <div class="flex-grow min-w-0">
            {{ $t('SIDEBAR.RECEIVE_CALLS.TEXT') }}
            <Icon
              v-tooltip.top="$t('SIDEBAR.RECEIVE_CALLS.INFO_SHORT')"
              icon="i-lucide-info"
              class="inline-block align-middle ms-1 size-4 text-n-slate-10"
            />
          </div>
          <ToggleSwitch v-model="receiveCalls" />
        </DropdownItem>
        <DropdownItem preserve-open class="gap-1">
          <div class="flex-grow min-w-0">
            {{ $t('SIDEBAR.CALL_PAUSE.TEXT') }}
          </div>
          <Select
            v-model="callPauseMinutes"
            :options="callPauseOptions"
            :aria-label="$t('SIDEBAR.CALL_PAUSE.TEXT')"
          />
        </DropdownItem>
      </template>
    </div>
  </DropdownSection>
</template>
