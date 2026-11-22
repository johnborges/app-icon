package com.example.app;

import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;
import android.webkit.ValueCallback;
import com.getcapacitor.BridgeActivity;

/**
 * Evidence hook for issue 66. Drives the AppIcon plugin from CI without
 * changing plugin source. change() is AppIcon.change({name:'ionic',
 * disable:['stencil','ionitron']}). reset() is AppIcon.reset({disable:
 * ['ionic','stencil','ionitron']}), which re-enables MainActivity.
 */
public class MainActivity extends BridgeActivity {

    static final String TAG = "AI66";
    static volatile MainActivity instance;

    private String lastRequest = "";

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        instance = this;
        Log.i(TAG, "CREATE pid=" + Process.myPid());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        runFromIntent(intent);
    }

    @Override
    public void onResume() {
        super.onResume();
        instance = this;
        Log.i(TAG, "RESUME pid=" + Process.myPid());
        runFromIntent(getIntent());
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "DESTROY pid=" + Process.myPid());
        if (instance == this) {
            instance = null;
        }
        super.onDestroy();
    }

    public void runFromIntent(Intent intent) {
        if (intent == null) {
            return;
        }
        String action = intent.getStringExtra("evidenceAction");
        if (action == null) {
            return;
        }
        String icon = intent.getStringExtra("evidenceIcon");
        if (!"change".equals(action) && !"reset".equals(action) && !"getname".equals(action)) {
            Log.e(TAG, "REJECT action=" + action);
            return;
        }
        if ("change".equals(action) && (icon == null || !icon.matches("ionic|stencil|ionitron"))) {
            Log.e(TAG, "REJECT icon=" + icon);
            return;
        }
        String key = action + ":" + (icon == null ? "" : icon);
        if (key.equals(lastRequest)) {
            return;
        }
        lastRequest = key;
        Log.i(TAG, "REQUEST " + key + " pid=" + Process.myPid());
        new Handler(Looper.getMainLooper()).postDelayed(() -> tryRun(action, icon, 0), 1500);
    }

    private void tryRun(String action, String icon, int attempt) {
        if (getBridge() == null || getBridge().getWebView() == null) {
            retry(action, icon, attempt, "bridge-not-ready");
            return;
        }
        String js;
        if ("change".equals(action)) {
            js = changeJs(icon);
        } else if ("reset".equals(action)) {
            js = resetJs();
        } else {
            js = getNameJs();
        }
        getBridge().eval(js, (ValueCallback<String>) value -> {
            Log.i(TAG, "EVAL " + action + " " + value + " pid=" + Process.myPid());
            if (value != null && value.contains("wait")) {
                retry(action, icon, attempt, "plugin-not-registered");
            }
        });
    }

    private void retry(String action, String icon, int attempt, String reason) {
        if (attempt >= 15) {
            Log.e(TAG, "GAVE_UP " + action + " after " + reason + " pid=" + Process.myPid());
            return;
        }
        new Handler(Looper.getMainLooper()).postDelayed(() -> tryRun(action, icon, attempt + 1), 1000);
    }

    private String changeJs(String icon) {
        return "(function(){"
            + "if(!window.Capacitor||!window.Capacitor.Plugins||!window.Capacitor.Plugins.AppIcon){return 'wait';}"
            + "var disable=['ionic','stencil','ionitron'].filter(function(n){return n!=='" + icon + "';});"
            + "console.log('AI66_CHANGE_CALL name=" + icon + " disable='+disable.join(','));"
            + "window.Capacitor.Plugins.AppIcon.change({name:'" + icon + "',suppressNotification:true,disable:disable})"
            + ".then(function(){console.log('AI66_CHANGE_OK');})"
            + ".catch(function(e){console.log('AI66_CHANGE_ERR '+(e&&e.message?e.message:e));});"
            + "return 'called';"
            + "})()";
    }

    private String resetJs() {
        return "(function(){"
            + "if(!window.Capacitor||!window.Capacitor.Plugins||!window.Capacitor.Plugins.AppIcon){return 'wait';}"
            + "console.log('AI66_RESET_CALL disable=ionic,stencil,ionitron');"
            + "window.Capacitor.Plugins.AppIcon.reset({suppressNotification:true,disable:['ionic','stencil','ionitron']})"
            + ".then(function(){console.log('AI66_RESET_OK');})"
            + ".catch(function(e){console.log('AI66_RESET_ERR '+(e&&e.message?e.message:e));});"
            + "return 'called';"
            + "})()";
    }

    // Separate from reset so a null launch intent cannot kill the process
    // before the reset captures are on disk. The NPE, when it happens, is
    // its own finding.
    private String getNameJs() {
        return "(function(){"
            + "if(!window.Capacitor||!window.Capacitor.Plugins||!window.Capacitor.Plugins.AppIcon){return 'wait';}"
            + "console.log('AI66_GETNAME_CALL');"
            + "window.Capacitor.Plugins.AppIcon.getName()"
            + ".then(function(r){console.log('AI66_GETNAME_RESULT '+JSON.stringify(r));})"
            + ".catch(function(e){console.log('AI66_GETNAME_ERR '+(e&&e.message?e.message:e));});"
            + "return 'called';"
            + "})()";
    }
}
