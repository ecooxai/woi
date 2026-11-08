package dev.woi.woi;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.TextView;

/** Test APK only: preserve the full original clip locally on the phone.
 * Clip contents never enter instrumentation results, files, logs, or intents.
 * A per-run opaque token prevents one fixture restoring another run's clip. */
public class ClipboardSnapshotActivity extends Activity {
    private static String savedId;
    private static String restoredId;
    private static ClipData savedClip;
    private TextView status;
    private boolean scheduled;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        status = new TextView(this);
        status.setGravity(Gravity.CENTER);
        status.setTextSize(18f);
        status.setPadding(24, 48, 24, 48);
        setContentView(status);
        prepare();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        prepare();
    }

    private void prepare() {
        scheduled = false;
        status.setContentDescription("woi-clipboard-snapshot-" + getIntent().getStringExtra("request"));
        status.setText("waiting");
        if ("close".equals(getIntent().getStringExtra("action"))) { finish(); return; }
        schedule();
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused) schedule();
    }

    private static boolean requiresUriGrant(ClipData clip, int depth) {
        if (clip == null) return false;
        if (depth > 8) return true;
        for (int i = 0; i < clip.getItemCount(); i++) {
            ClipData.Item item = clip.getItemAt(i);
            android.net.Uri uri = item.getUri();
            if (uri != null && ("content".equalsIgnoreCase(uri.getScheme()) || "file".equalsIgnoreCase(uri.getScheme()))) return true;
            Intent intent = item.getIntent();
            if (intent != null) {
                uri = intent.getData();
                if (uri != null && ("content".equalsIgnoreCase(uri.getScheme()) || "file".equalsIgnoreCase(uri.getScheme()))) return true;
                if (requiresUriGrant(intent.getClipData(), depth + 1)) return true;
            }
        }
        return false;
    }

    private void schedule() {
        if (status == null || scheduled || !hasWindowFocus()) return;
        scheduled = true;
        String id = getIntent().getStringExtra("request");
        String action = getIntent().getStringExtra("action");
        status.postDelayed(() -> {
            scheduled = false;
            if (!hasWindowFocus() || !java.util.Objects.equals(id, getIntent().getStringExtra("request")) ||
                    !java.util.Objects.equals(action, getIntent().getStringExtra("action"))) return;
            ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            try {
                if ("save".equals(action)) {
                    if (savedId != null && !savedId.equals(id)) { status.setText("error: snapshot busy"); return; }
                    if (savedId == null) {
                        ClipData original = clipboard.getPrimaryClip();
                        // Replacing a clipboard revokes its URI grants. A
                        // memory copy cannot guarantee restoring those grants,
                        // so abort before any fixture clipboard writes.
                        if (requiresUriGrant(original, 0)) {
                            status.setText("error: URI clipboard cannot be safely overwritten");
                            return;
                        }
                        savedClip = original;
                        savedId = id;
                        restoredId = null;
                    }
                    status.setText("saved");
                } else if ("restore".equals(action)) {
                    if (id != null && id.equals(savedId)) {
                        if (savedClip == null) clipboard.clearPrimaryClip();
                        else clipboard.setPrimaryClip(savedClip);
                        savedClip = null;
                        savedId = null;
                        restoredId = id;
                    } else if (id == null || !id.equals(restoredId)) {
                        status.setText("error: snapshot missing");
                        return;
                    }
                    status.setText("restored");
                } else status.setText("error: unsupported action");
            } catch (Throwable error) {
                // Exception messages from providers could contain clip URIs.
                // Report only the exception type; retain the snapshot to retry.
                status.setText("error: " + error.getClass().getSimpleName());
            }
        }, 100);
    }
}
