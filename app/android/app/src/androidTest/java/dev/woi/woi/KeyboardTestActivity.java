package dev.woi.woi;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Neutral editor in the test APK only. No Flutter, network, microphone or camera. */
public class KeyboardTestActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 48, 24, 24);
        TextView heading = new TextView(this);
        heading.setText("WOI keyboard fixture — local test text only");
        root.addView(heading);
        TextView count = new TextView(this);
        count.setContentDescription("woi-keyboard-chord");
        count.setText("0");
        root.addView(count);
        TextView events = new TextView(this);
        events.setContentDescription("woi-keyboard-events");
        events.setText("0");
        root.addView(events);
        EditText editor = new EditText(this) {
            private int combined = 0;
            private int eventCount = 0;
            @Override public boolean dispatchKeyEvent(KeyEvent event) {
                eventCount++;
                events.setText(Integer.toString(eventCount));
                if (event.getAction() == KeyEvent.ACTION_DOWN && event.getKeyCode() == KeyEvent.KEYCODE_K
                        && event.isCtrlPressed() && event.isAltPressed() && event.isShiftPressed()) {
                    combined++;
                    count.setText(Integer.toString(combined));
                    return true;
                }
                return super.dispatchKeyEvent(event);
            }
        };
        editor.setContentDescription("woi-keyboard-input");
        editor.setSingleLine(false);
        editor.setMinLines(4);
        editor.setText("alpha beta");
        editor.setSelection(editor.length());
        root.addView(editor, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 240));
        setContentView(root);
        editor.requestFocus();
        editor.postDelayed(() -> ((InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE))
                .showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT), 150);
    }
}
