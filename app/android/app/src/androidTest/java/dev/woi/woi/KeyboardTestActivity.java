package dev.woi.woi;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.SurroundingText;
import android.view.inputmethod.TextSnapshot;
import android.view.WindowManager;
import android.widget.Button;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Neutral editor in the test APK only. No Flutter, network, microphone or camera. */
public class KeyboardTestActivity extends Activity {
    private TextView windowFocus;
    private String expectedClipboardText;
    public static final int PRIMARY_EDITOR_ID = 0x00d001;
    public static final int SECONDARY_EDITOR_ID = 0x00d002;

    /** Numeric lifecycle diagnostics only; editor/clipboard contents never leave the fixture. */
    private final class ConnectionTracker {
        final TextView marker;
        int created, closed, keys, queries, snapshots, lastKeyConnection;
        ConnectionTracker(LinearLayout root, String description) {
            marker = new TextView(KeyboardTestActivity.this);
            marker.setContentDescription(description);
            root.addView(marker);
            publish();
        }
        void publish() {
            runOnUiThread(() -> marker.setText("created=" + created + " closed=" + closed
                    + " keys=" + keys + " queries=" + queries + " snapshots=" + snapshots
                    + " last_key_connection=" + lastKeyConnection));
        }
        InputConnection wrap(InputConnection delegate, EditorInfo info) {
            if (delegate == null) return null;
            final int generation = ++created;
            if (info.extras == null) info.extras = new Bundle();
            info.extras.putInt("woi_fixture_connection", generation);
            publish();
            return new InputConnectionWrapper(delegate, false) {
                @Override public boolean sendKeyEvent(KeyEvent event) {
                    keys++;
                    lastKeyConnection = generation;
                    publish();
                    return super.sendKeyEvent(event);
                }
                @Override public SurroundingText getSurroundingText(int before, int after, int flags) {
                    queries++;
                    publish();
                    return super.getSurroundingText(before, after, flags);
                }
                @Override public TextSnapshot takeSnapshot() {
                    snapshots++;
                    publish();
                    return super.takeSnapshot();
                }
                @Override public void closeConnection() {
                    closed++;
                    publish();
                    super.closeConnection();
                }
            };
        }
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (windowFocus != null) windowFocus.setText(focused ? "focused" : "unfocused");
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 48, 24, 24);
        TextView heading = new TextView(this);
        heading.setText("WOI keyboard fixture — local test text only");
        root.addView(heading);
        windowFocus = new TextView(this);
        windowFocus.setContentDescription("woi-keyboard-window-focus");
        windowFocus.setText(hasWindowFocus() ? "focused" : "unfocused");
        root.addView(windowFocus);
        TextView count = new TextView(this);
        count.setContentDescription("woi-keyboard-chord");
        count.setText("0");
        root.addView(count);
        TextView events = new TextView(this);
        events.setContentDescription("woi-keyboard-events");
        events.setText("0");
        root.addView(events);
        TextView shortcutCounts = new TextView(this);
        shortcutCounts.setContentDescription("woi-keyboard-shortcut-counts");
        shortcutCounts.setText("a=0 c=0 x=0 v=0 selected=0");
        root.addView(shortcutCounts);
        TextView clipboardState = new TextView(this);
        clipboardState.setContentDescription("woi-keyboard-clipboard-state");
        clipboardState.setText("unarmed");
        root.addView(clipboardState);
        boolean noConnection = getIntent().getBooleanExtra("no_input_connection", false);
        boolean hideKeyboard = getIntent().getBooleanExtra("hide_keyboard", false);
        TextView mode = new TextView(this);
        mode.setContentDescription("woi-keyboard-mode");
        mode.setText(noConnection ? "no-input-connection" : "normal");
        root.addView(mode);
        ConnectionTracker primaryConnection = new ConnectionTracker(root, "woi-keyboard-primary-connection");
        ConnectionTracker secondaryConnection = new ConnectionTracker(root, "woi-keyboard-secondary-connection");
        EditText editor = new EditText(this) {
            @Override public boolean onCheckIsTextEditor() { return !noConnection && super.onCheckIsTextEditor(); }
            @Override public InputConnection onCreateInputConnection(EditorInfo info) {
                return noConnection ? null : primaryConnection.wrap(super.onCreateInputConnection(info), info);
            }
            private int combined = 0;
            private int eventCount = 0;
            private int aKeys = 0, cKeys = 0, xKeys = 0, vKeys = 0, selected = 0;
            @Override public boolean dispatchKeyEvent(KeyEvent event) {
                eventCount++;
                events.setText(Integer.toString(eventCount));
                if (event.getAction() == KeyEvent.ACTION_DOWN && event.getKeyCode() == KeyEvent.KEYCODE_K
                        && event.isCtrlPressed() && event.isAltPressed() && event.isShiftPressed()) {
                    combined++;
                    count.setText(Integer.toString(combined));
                    return true;
                }
                boolean handled = super.dispatchKeyEvent(event);
                recordShortcut(event);
                return handled;
            }
            @Override public boolean dispatchKeyShortcutEvent(KeyEvent event) {
                boolean handled = super.dispatchKeyShortcutEvent(event);
                // Android may consume Ctrl+A/C/X/V through the shortcut route
                // before the ordinary dispatchKeyEvent route is reached.
                if (handled) recordShortcut(event);
                return handled;
            }
            private void recordShortcut(KeyEvent event) {
                if (event.getAction() == KeyEvent.ACTION_DOWN && event.isCtrlPressed()) {
                    switch (event.getKeyCode()) {
                        case KeyEvent.KEYCODE_A:
                            aKeys++;
                            if (getSelectionStart() == 0 && getSelectionEnd() == length()) selected++;
                            break;
                        case KeyEvent.KEYCODE_C: cKeys++; break;
                        case KeyEvent.KEYCODE_X: xKeys++; break;
                        case KeyEvent.KEYCODE_V: vKeys++; break;
                        default: break;
                    }
                    // Published after the receiving editor handles the event,
                    // rather than when the accessibility service dispatches it.
                    shortcutCounts.setText("a=" + aKeys + " c=" + cKeys + " x=" + xKeys + " v=" + vKeys + " selected=" + selected);
                }
            }
        };
        editor.setId(PRIMARY_EDITOR_ID);
        editor.setContentDescription("woi-keyboard-input");
        editor.setSingleLine(false);
        editor.setShowSoftInputOnFocus(!hideKeyboard);
        editor.setMinLines(4);
        editor.setText("alpha beta");
        editor.setSelection(editor.length());
        root.addView(editor, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 240));
        EditText secondary = new EditText(this) {
            @Override public boolean onCheckIsTextEditor() { return !noConnection && super.onCheckIsTextEditor(); }
            @Override public InputConnection onCreateInputConnection(EditorInfo info) {
                return noConnection ? null : secondaryConnection.wrap(super.onCreateInputConnection(info), info);
            }
        };
        secondary.setId(SECONDARY_EDITOR_ID);
        secondary.setContentDescription("woi-keyboard-secondary-input");
        secondary.setSingleLine(false);
        secondary.setShowSoftInputOnFocus(!hideKeyboard);
        secondary.setText("secondary fixture");
        secondary.setSelection(secondary.length());
        root.addView(secondary, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 120));
        LinearLayout clipboardButtons = new LinearLayout(this);
        Button armClipboard = new Button(this);
        armClipboard.setText("Arm local copy check");
        armClipboard.setContentDescription("woi-keyboard-clipboard-arm");
        armClipboard.setFocusable(false);
        armClipboard.setOnClickListener(view -> {
            expectedClipboardText = editor.getText().toString();
            clipboardState.setText("pending");
        });
        clipboardButtons.addView(armClipboard, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button probeClipboard = new Button(this);
        probeClipboard.setText("Check copied text");
        probeClipboard.setContentDescription("woi-keyboard-clipboard-probe");
        probeClipboard.setFocusable(false);
        probeClipboard.setOnClickListener(view -> {
            if (expectedClipboardText == null) { clipboardState.setText("unarmed"); return; }
            if (!hasWindowFocus()) { clipboardState.setText("not_focused"); return; }
            try {
                android.content.ClipData clip = ((android.content.ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE)).getPrimaryClip();
                CharSequence copied = clip != null && clip.getItemCount() > 0 ? clip.getItemAt(0).getText() : null;
                // The clipboard value stays inside this fixture process.
                // Instrumentation receives only the equality flag.
                clipboardState.setText(expectedClipboardText.contentEquals(copied == null ? "" : copied) ? "matched" : "different");
            } catch (Throwable error) {
                clipboardState.setText("unavailable");
            }
        });
        clipboardButtons.addView(probeClipboard, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        root.addView(clipboardButtons);
        Button restartInput = new Button(this);
        restartInput.setText("Prepare exact-key connection");
        restartInput.setContentDescription("woi-keyboard-restart-input");
        restartInput.setFocusable(false);
        restartInput.setOnClickListener(view -> ((InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE)).restartInput(editor));
        root.addView(restartInput);
        Button hide = new Button(this);
        hide.setText("Hide keyboard");
        hide.setContentDescription("woi-keyboard-hide");
        hide.setFocusable(false);
        hide.setOnClickListener(view -> {
            editor.setShowSoftInputOnFocus(false);
            ((InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE))
                    .hideSoftInputFromWindow(editor.getWindowToken(), 0);
        });
        root.addView(hide);
        Button leaveEditor = new Button(this);
        leaveEditor.setText("Leave editor");
        leaveEditor.setContentDescription("woi-keyboard-leave-editor");
        leaveEditor.setOnClickListener(view -> {
            root.setFocusableInTouchMode(true);
            root.requestFocus();
            ((InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE))
                    .hideSoftInputFromWindow(editor.getWindowToken(), 0);
        });
        root.addView(leaveEditor);
        Button modal = new Button(this);
        modal.setText("Open no-editor dialog");
        modal.setContentDescription("woi-keyboard-open-dialog");
        modal.setFocusable(false);
        modal.setOnClickListener(view -> {
            android.app.AlertDialog dialog = new android.app.AlertDialog.Builder(this)
                    .setTitle("Keyboard focus fixture")
                    .setMessage("This window has no editable field.")
                    .setPositiveButton("Return to editor", (d, which) -> d.dismiss())
                    .create();
            dialog.show();
            dialog.findViewById(android.R.id.message).setContentDescription("woi-keyboard-dialog");
            dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE)
                    .setContentDescription("woi-keyboard-dialog-close");
        });
        root.addView(modal);
        if (hideKeyboard) getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        setContentView(root);
        editor.requestFocus();
        if (!hideKeyboard && !noConnection) editor.postDelayed(() -> ((InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE))
                .showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT), 150);
    }
}
