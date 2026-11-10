package dev.woi.woi;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.Arrays;
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
    static final String FIXTURE_TEXT = "alpha bravo charlie\nWOI QA clipboard 20261109\n中文测试 蓝莓 葡萄\n你好世界\n雪🙂";
    static final String FIXTURE_FILE = "woi-clipboard-synthetic.png";

    static byte[] fixtureImage() {
        Bitmap bitmap = Bitmap.createBitmap(3, 2, Bitmap.Config.ARGB_8888);
        bitmap.eraseColor(Color.MAGENTA);
        bitmap.setPixel(2, 1, Color.GREEN);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        bitmap.recycle();
        return bytes.toByteArray();
    }

    public static boolean canSafelyReplace(ClipData clip) { return !requiresUriGrant(clip, 0); }

    private boolean ownsSnapshot(String id) {
        if (id == null || !id.equals(savedId)) { status.setText("error: snapshot missing"); return false; }
        return true;
    }

    private void verifyText(ClipboardManager clipboard) {
        String expected = getIntent().getStringExtra("expected_text");
        if (!FIXTURE_TEXT.equals(expected) && !"bravo".equals(expected) && !"蓝莓".equals(expected) && !"雪🙂".equals(expected)) {
            status.setText("error: unsupported synthetic expectation"); return;
        }
        ClipData clip = clipboard.getPrimaryClip();
        CharSequence actual = clip == null || clip.getItemCount() == 0 ? null : clip.getItemAt(0).getText();
        status.setText(expected.contentEquals(actual == null ? "" : actual) ? "text_match" : "text_mismatch");
    }

    private void verifyImage(ClipboardManager clipboard) throws Exception {
        ClipData clip = clipboard.getPrimaryClip();
        Uri uri = clip == null || clip.getItemCount() == 0 ? null : clip.getItemAt(0).getUri();
        if (uri == null) { status.setText("image_missing_uri"); return; }
        if (!"dev.woi.woi.clipboard".equals(uri.getAuthority())) { status.setText("image_wrong_source"); return; }
        if (!"image/png".equals(getContentResolver().getType(uri))) { status.setText("image_mime_mismatch"); return; }
        ByteArrayOutputStream data = new ByteArrayOutputStream();
        try (InputStream stream = getContentResolver().openInputStream(uri)) {
            if (stream == null) { status.setText("image_unreadable"); return; }
            byte[] buffer = new byte[4096];
            for (int n; (n = stream.read(buffer)) != -1;) {
                if (data.size() + n > 1024 * 1024) { status.setText("image_over_limit"); return; }
                data.write(buffer, 0, n);
            }
        }
        if (!Arrays.equals(fixtureImage(), data.toByteArray())) { status.setText("image_bytes_mismatch"); return; }
        boolean readOnly = false;
        try { android.os.ParcelFileDescriptor fd = getContentResolver().openFileDescriptor(uri, "w"); if (fd != null) fd.close(); }
        catch (Exception expected) { readOnly = true; }
        status.setText(readOnly ? "image_match_read_only" : "image_writable");
    }

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
                } else if ("seed_unicode".equals(action)) {
                    if (!ownsSnapshot(id)) return;
                    clipboard.setPrimaryClip(ClipData.newPlainText("Woi QA fixture", FIXTURE_TEXT));
                    status.setText("seeded_unicode");
                } else if ("seed_image".equals(action)) {
                    if (!ownsSnapshot(id)) return;
                    File file = new File(getCacheDir(), FIXTURE_FILE);
                    try (FileOutputStream stream = new FileOutputStream(file)) { stream.write(fixtureImage()); }
                    Uri uri = Uri.parse("content://" + getPackageName() + ".fixture.clipboard/synthetic.png");
                    clipboard.setPrimaryClip(ClipData.newUri(getContentResolver(), "Woi QA fixture image", uri));
                    status.setText("seeded_image");
                } else if ("verify_text".equals(action)) {
                    if (!ownsSnapshot(id)) return;
                    verifyText(clipboard);
                } else if ("verify_image".equals(action)) {
                    if (!ownsSnapshot(id)) return;
                    verifyImage(clipboard);
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
                    new File(getCacheDir(), FIXTURE_FILE).delete();
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
