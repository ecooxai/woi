package dev.woi.woi;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** SDK-only neutral activity: it can run in the test APK's own process without
 * relying on the target application's Kotlin/runtime dependencies. */
public class ControlOverlayTestActivity extends Activity {
    private int clicks;
    private int dp(int value) { return (int) (value * getResources().getDisplayMetrics().density); }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(56), dp(24), dp(24));
        content.setBackgroundColor(Color.WHITE);
        TextView title = new TextView(this);
        title.setText("Woi native control test");
        title.setTextSize(22);
        title.setTextColor(Color.BLACK);
        content.addView(title, new LinearLayout.LayoutParams(-1, dp(56)));
        EditText editor = new EditText(this);
        editor.setContentDescription("woi-test-input");
        editor.setHint("Test typing appears here");
        editor.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        editor.setTextColor(Color.BLACK);
        editor.setHintTextColor(Color.DKGRAY);
        editor.setBackgroundColor(Color.rgb(245, 245, 245));
        editor.setShowSoftInputOnFocus(false);
        content.addView(editor, new LinearLayout.LayoutParams(-1, dp(96)));
        content.addView(new View(this), new LinearLayout.LayoutParams(-1, dp(24)));
        final TextView counter = new TextView(this);
        counter.setContentDescription("woi-test-count");
        counter.setText("Touches: 0");
        counter.setTextSize(18);
        counter.setTextColor(Color.BLACK);
        Button button = new Button(this);
        button.setContentDescription("woi-test-button");
        button.setText("Touch target");
        button.setTextColor(Color.BLACK);
        button.setBackgroundColor(Color.rgb(225, 225, 225));
        button.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View view) {
                clicks++;
                counter.setText("Touches: " + clicks);
            }
        });
        content.addView(button, new LinearLayout.LayoutParams(-1, dp(88)));
        content.addView(counter, new LinearLayout.LayoutParams(-1, dp(56)));
        setContentView(content);
        editor.requestFocus();
    }
}
