package org.webrtc.audio;

import android.media.AudioAttributes;

/**
 * Sets the next WebRTC playout's attributes between peer connections.
 *
 * The pinned webrtc-sdk exposes JavaAudioDeviceModule.audioOutput and its
 * mutable audioAttributes, but WebRtcAudioTrack itself is package-private.
 * This tiny package bridge uses those fields directly (no reflection and no
 * changes to downloaded plugin sources). AudioSwitch configuration alone only
 * changes focus/routing; it does not change an existing ADM's next AudioTrack.
 */
public final class WoiAudioRouteAccess {
    private WoiAudioRouteAccess() {}

    public static void configure(JavaAudioDeviceModule module, boolean media) {
        module.audioOutput.audioAttributes = new AudioAttributes.Builder()
                .setUsage(media ? AudioAttributes.USAGE_MEDIA : AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build();
    }

    public static int usage(JavaAudioDeviceModule module) {
        AudioAttributes attributes = module.audioOutput.audioAttributes;
        return attributes == null ? AudioAttributes.USAGE_VOICE_COMMUNICATION : attributes.getUsage();
    }
}
