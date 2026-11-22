package com.example.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Explicit exported receiver so CI can invoke change/reset without relaunching
 * the singleTask activity. A second am start drops extras on this activity.
 */
public class HarnessReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getStringExtra("evidenceAction");
        Log.i(MainActivity.TAG, "BROADCAST " + action);
        MainActivity activity = MainActivity.instance;
        if (activity == null) {
            Log.e(MainActivity.TAG, "BROADCAST_NO_ACTIVITY " + action);
            return;
        }
        activity.runFromIntent(intent);
    }
}
