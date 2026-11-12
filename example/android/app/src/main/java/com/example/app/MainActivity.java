package com.example.app;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.ValueCallback;
import androidx.activity.EdgeToEdge;
import com.getcapacitor.BridgeActivity;

/**
 * Evidence-only hook for the Capacitor 9 example run. Present on the scratch
 * branch so a CI emulator can ask the AppIcon plugin to change the launcher icon.
 */
public class MainActivity extends BridgeActivity {

    private static final String TAG = "EvidenceIcon";
    private boolean evidenceStarted = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        EdgeToEdge.enable(this);
    }

    @Override
    public void onResume() {
        super.onResume();
        if (evidenceStarted) {
            return;
        }
        String icon = getIntent().getStringExtra("evidenceIcon");
        if (icon == null) {
            return;
        }
        if (!icon.equals("ionic") && !icon.equals("stencil") && !icon.equals("ionitron")) {
            Log.e(TAG, "EVIDENCE_ICON_ERR rejected name " + icon);
            return;
        }
        evidenceStarted = true;
        Log.i(TAG, "EVIDENCE_ICON_REQUEST " + icon);
        new Handler(Looper.getMainLooper()).postDelayed(() -> tryEvidence(icon, 0), 2000);
    }

    private void tryEvidence(String icon, int attempt) {
        if (getBridge() == null || getBridge().getWebView() == null) {
            retry(icon, attempt, "bridge-not-ready");
            return;
        }
        String js =
            "(function(){" +
            "if(!window.Capacitor||!window.Capacitor.Plugins||!window.Capacitor.Plugins.AppIcon){return 'wait';}" +
            "var disable=['ionic','stencil','ionitron'].filter(function(n){return n!=='" + icon + "';});" +
            "window.Capacitor.Plugins.AppIcon.change({name:'" + icon + "',disable:disable})" +
            ".then(function(){console.log('EVIDENCE_ICON_OK');})" +
            ".catch(function(e){console.log('EVIDENCE_ICON_ERR '+(e&&e.message?e.message:e));});" +
            "return 'called';" +
            "})()";
        getBridge().eval(js, (ValueCallback<String>) value -> {
            Log.i(TAG, "EVIDENCE_ICON_EVAL " + value);
            if (value != null && value.contains("wait")) {
                retry(icon, attempt, "plugin-not-registered");
            }
        });
    }

    private void retry(String icon, int attempt, String reason) {
        if (attempt >= 12) {
            Log.e(TAG, "EVIDENCE_ICON_ERR gave up after " + reason);
            return;
        }
        new Handler(Looper.getMainLooper()).postDelayed(() -> tryEvidence(icon, attempt + 1), 1000);
    }
}
