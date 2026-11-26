package com.mycompany.plugins.example;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Application;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Bundle;
import android.util.Log;
import com.getcapacitor.JSArray;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.json.JSONException;

public class AppIconBase {

    private static final String TAG = "AppIconBase";
    private static final String PREFS = "com.mycompany.plugins.example.AppIcon";
    private static final String KEY_MODE = "pending_mode";
    private static final String KEY_KEEP = "pending_keep";
    private static final String KEY_NAMES = "pending_names";
    private static final String MODE_DISABLE = "disable";
    private static final String MODE_DEFAULTS = "defaults";
    private static final Object LOCK = new Object();
    private static boolean callbacksRegistered;
    private static boolean applying;

    private final Context context;
    private final String packageName;
    private final PackageManager pm;

    public AppIconBase(Activity activity, Context context) {
        Context source = activity != null ? activity : context;
        this.context = source;
        this.packageName = source.getPackageName();
        this.pm = source.getApplicationContext().getPackageManager();
        registerStopCallback(source);
        // Process death before onStop leaves the pending disable on disk.
        applyPending(source, "next-start");
    }

    public Boolean isSupported() {
        return true;
    }

    public String getName() {
        try {
            ComponentName componentName = currentLauncher();
            if (componentName == null) {
                Log.i(TAG, "getName=null");
                return null;
            }
            String name = shortName(componentName);
            if (name == null || "MainActivity".equals(name)) {
                Log.i(TAG, "getName=null component=" + componentName.flattenToShortString());
                return null;
            }
            int status = pm.getComponentEnabledSetting(componentName);
            if (
                status != PackageManager.COMPONENT_ENABLED_STATE_ENABLED &&
                status != PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
            ) {
                Log.i(TAG, "getName=null disabled " + name);
                return null;
            }
            Log.i(TAG, "getName=" + name);
            return name;
        } catch (RuntimeException ex) {
            Log.e(TAG, "getName failed", ex);
            return null;
        }
    }

    public void change(String enableName, JSArray disableNames) {
        // The alias that owns the resumed task is still enabled. Disabling it
        // finishes that activity (disabled-package) even with DONT_KILL_APP, so
        // the old aliases stay up until the host activity stops. No relaunch.
        if (isMainActivity(enableName)) {
            Log.e(TAG, "refusing icon name " + enableName);
            return;
        }
        try {
            List<String> names = stringList(disableNames);
            setState(pm, packageName, enableName, PackageManager.COMPONENT_ENABLED_STATE_ENABLED);
            Log.i(TAG, "enabled " + enableName);
            savePending(MODE_DISABLE, enableName, names);
            Log.i(TAG, "deferred disable until background keep=" + enableName);
        } catch (JSONException ex) {
            Log.e(TAG, "change failed to read disable list", ex);
        }
    }

    public void reset(JSArray disableNames) {
        try {
            List<String> names = stringList(disableNames);
            List<LauncherAlias> launchers = queryLauncherAliases();
            String defaultAlias = null;
            String current = null;
            int manifestDefaults = 0;
            for (LauncherAlias launcher : launchers) {
                if (launcher.manifestEnabled) {
                    manifestDefaults += 1;
                    if (defaultAlias == null) {
                        defaultAlias = launcher.alias;
                    }
                }
                if (launcher.currentlyEnabled && current == null) {
                    current = launcher.alias;
                }
            }
            Log.i(TAG, "reset default=" + defaultAlias + " current=" + current + " manifestDefaults=" + manifestDefaults);
            if (isMainActivity(defaultAlias)) {
                Log.e(TAG, "no manifest default launcher alias; leaving component state unchanged");
                return;
            }
            setState(pm, packageName, defaultAlias, PackageManager.COMPONENT_ENABLED_STATE_ENABLED);
            Log.i(TAG, "enabled " + defaultAlias);
            savePending(MODE_DEFAULTS, defaultAlias, names);
            Log.i(TAG, "deferred manifest restore until background keep=" + defaultAlias);
        } catch (JSONException ex) {
            Log.e(TAG, "reset failed to read disable list", ex);
        }
    }

    private void savePending(String mode, String keep, List<String> names) {
        SharedPreferences prefs = prefs(context);
        Set<String> stored = new HashSet<>();
        for (String name : names) {
            if (!isMainActivity(name)) {
                stored.add(name);
            }
        }
        synchronized (LOCK) {
            prefs.edit().putString(KEY_MODE, mode).putString(KEY_KEEP, keep).putStringSet(KEY_NAMES, stored).commit();
        }
    }

    private static void registerStopCallback(Context context) {
        Context appContext = context.getApplicationContext();
        if (!(appContext instanceof Application)) {
            Log.e(TAG, "no application to watch for background");
            return;
        }
        synchronized (LOCK) {
            if (callbacksRegistered) {
                return;
            }
            ((Application) appContext).registerActivityLifecycleCallbacks(new StopCallback());
            callbacksRegistered = true;
        }
    }

    static void applyPending(Context context, String reason) {
        if (context == null) {
            return;
        }
        SharedPreferences prefs = prefs(context);
        String mode;
        String keep;
        List<String> names;
        synchronized (LOCK) {
            if (applying) {
                return;
            }
            mode = prefs.getString(KEY_MODE, null);
            if (mode == null) {
                return;
            }
            applying = true;
            keep = prefs.getString(KEY_KEEP, "");
            Set<String> stored = prefs.getStringSet(KEY_NAMES, new HashSet<String>());
            names = new ArrayList<>();
            if (stored != null) {
                names.addAll(stored);
            }
        }
        try {
            String packageName = context.getPackageName();
            PackageManager manager = context.getPackageManager();
            Log.i(
                TAG,
                "applying deferred alias update reason=" +
                    reason +
                    " mode=" +
                    mode +
                    " keep=" +
                    keep +
                    " names=" +
                    names
            );
            if (MODE_DEFAULTS.equals(mode)) {
                if (!isMainActivity(keep)) {
                    setState(manager, packageName, keep, PackageManager.COMPONENT_ENABLED_STATE_ENABLED);
                }
                for (String name : names) {
                    if (isMainActivity(name) || name.equals(keep)) {
                        continue;
                    }
                    setState(manager, packageName, name, PackageManager.COMPONENT_ENABLED_STATE_DEFAULT);
                    Log.i(TAG, "defaulted " + name);
                }
                if (!isMainActivity(keep)) {
                    setState(manager, packageName, keep, PackageManager.COMPONENT_ENABLED_STATE_DEFAULT);
                    Log.i(TAG, "defaulted " + keep);
                }
            } else {
                for (String name : names) {
                    if (isMainActivity(name) || name.equals(keep)) {
                        continue;
                    }
                    setState(manager, packageName, name, PackageManager.COMPONENT_ENABLED_STATE_DISABLED);
                    Log.i(TAG, "disabled " + name);
                }
            }
            synchronized (LOCK) {
                prefs.edit().remove(KEY_MODE).remove(KEY_KEEP).remove(KEY_NAMES).commit();
            }
        } catch (RuntimeException ex) {
            Log.e(TAG, "deferred alias update failed reason=" + reason, ex);
        } finally {
            synchronized (LOCK) {
                applying = false;
            }
        }
    }

    private static void setState(PackageManager manager, String pkg, String alias, int state) {
        if (isMainActivity(alias)) {
            Log.e(TAG, "refusing to change MainActivity");
            return;
        }
        manager.setComponentEnabledSetting(
            new ComponentName(pkg, pkg + "." + alias),
            state,
            PackageManager.DONT_KILL_APP
        );
    }

    @SuppressLint("QueryPermissionsNeeded")
    private List<LauncherAlias> queryLauncherAliases() {
        Map<String, ActivityInfo> byName = new HashMap<>();
        int packageActivities = 0;
        try {
            PackageInfo info = packageInfo();
            if (info.activities != null) {
                packageActivities = info.activities.length;
                for (ActivityInfo activityInfo : info.activities) {
                    if (activityInfo == null || activityInfo.name == null) {
                        continue;
                    }
                    byName.put(activityInfo.name, activityInfo);
                    Log.i(
                        TAG,
                        "package activity=" +
                            activityInfo.name +
                            " manifestEnabled=" +
                            activityInfo.enabled +
                            " target=" +
                            activityInfo.targetActivity
                    );
                }
            }
        } catch (Exception ex) {
            Log.e(TAG, "package activity lookup failed", ex);
        }

        Map<String, ResolveInfo> resolved = new HashMap<>();
        collectLaunchers(resolved, queryFlags(false));
        collectLaunchers(resolved, queryFlags(true));
        boolean sawManifestDefault = false;
        for (Map.Entry<String, ResolveInfo> entry : resolved.entrySet()) {
            ActivityInfo activityInfo = byName.get(entry.getKey());
            if (activityInfo == null && entry.getValue() != null) {
                activityInfo = entry.getValue().activityInfo;
            }
            if (activityInfo == null || !activityInfo.enabled) {
                continue;
            }
            if (!isMainActivity(aliasFromClassName(packageName, activityInfo.name))) {
                sawManifestDefault = true;
            }
        }
        // queryIntentActivities can omit a runtime-disabled alias. The manifest
        // default is still in getPackageInfo and is the alias reset() must restore.
        if (!sawManifestDefault) {
            Log.w(TAG, "query missed the manifest-enabled alias; scanning package activities");
            for (ActivityInfo activityInfo : byName.values()) {
                if (activityInfo.targetActivity == null || !activityInfo.enabled) {
                    continue;
                }
                String alias = aliasFromClassName(packageName, activityInfo.name);
                if (isMainActivity(alias)) {
                    continue;
                }
                resolved.put(activityInfo.name, null);
            }
        }

        List<LauncherAlias> result = new ArrayList<>();
        for (Map.Entry<String, ResolveInfo> entry : resolved.entrySet()) {
            String className = entry.getKey();
            ActivityInfo fromPackage = byName.get(className);
            ActivityInfo activityInfo = fromPackage;
            if (activityInfo == null && entry.getValue() != null) {
                activityInfo = entry.getValue().activityInfo;
            }
            if (activityInfo == null || activityInfo.name == null) {
                continue;
            }
            String alias = aliasFromClassName(packageName, activityInfo.name);
            if (isMainActivity(alias)) {
                continue;
            }
            String pkg = activityInfo.packageName != null ? activityInfo.packageName : packageName;
            int setting = pm.getComponentEnabledSetting(new ComponentName(pkg, activityInfo.name));
            // ActivityInfo.enabled is the manifest android:enabled value.
            // getComponentEnabledSetting is the runtime override (DEFAULT = manifest).
            boolean manifestEnabled = activityInfo.enabled;
            boolean currentlyEnabled =
                setting == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
                (setting == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && manifestEnabled);
            Log.i(
                TAG,
                "launcher alias=" +
                    alias +
                    " manifestEnabled=" +
                    manifestEnabled +
                    " setting=" +
                    setting +
                    " current=" +
                    currentlyEnabled
            );
            result.add(new LauncherAlias(alias, manifestEnabled, currentlyEnabled));
        }
        Log.i(TAG, "launcher candidates=" + result.size() + " packageActivities=" + packageActivities);
        return result;
    }

    @SuppressLint("QueryPermissionsNeeded")
    private void collectLaunchers(Map<String, ResolveInfo> into, int flags) {
        Intent query = new Intent(Intent.ACTION_MAIN);
        query.addCategory(Intent.CATEGORY_LAUNCHER);
        query.setPackage(packageName);
        List<ResolveInfo> matches;
        try {
            matches = pm.queryIntentActivities(query, flags);
        } catch (RuntimeException ex) {
            Log.e(TAG, "queryIntentActivities failed flags=" + flags, ex);
            return;
        }
        if (matches == null) {
            return;
        }
        for (ResolveInfo resolve : matches) {
            if (resolve == null || resolve.activityInfo == null || resolve.activityInfo.name == null) {
                continue;
            }
            into.put(resolve.activityInfo.name, resolve);
        }
    }

    private int queryFlags(boolean includeDisabled) {
        int flags = PackageManager.MATCH_DIRECT_BOOT_AWARE | PackageManager.MATCH_DIRECT_BOOT_UNAWARE;
        if (includeDisabled) {
            flags |= PackageManager.MATCH_DISABLED_COMPONENTS;
        }
        return flags;
    }

    @SuppressWarnings("deprecation")
    private PackageInfo packageInfo() throws PackageManager.NameNotFoundException {
        int flags =
            PackageManager.MATCH_DISABLED_COMPONENTS |
            PackageManager.GET_ACTIVITIES |
            PackageManager.MATCH_DIRECT_BOOT_AWARE |
            PackageManager.MATCH_DIRECT_BOOT_UNAWARE;
        return pm.getPackageInfo(packageName, flags);
    }

    @SuppressLint("QueryPermissionsNeeded")
    private ComponentName currentLauncher() {
        Intent intent = pm.getLaunchIntentForPackage(packageName);
        if (intent != null && intent.getComponent() != null) {
            return intent.getComponent();
        }
        Intent query = new Intent(Intent.ACTION_MAIN);
        query.addCategory(Intent.CATEGORY_LAUNCHER);
        query.setPackage(packageName);
        List<ResolveInfo> matches = pm.queryIntentActivities(query, queryFlags(false));
        if (matches == null) {
            return null;
        }
        for (ResolveInfo info : matches) {
            if (info.activityInfo == null) {
                continue;
            }
            return new ComponentName(info.activityInfo.packageName, info.activityInfo.name);
        }
        return null;
    }

    private String shortName(ComponentName componentName) {
        if (componentName == null) {
            return null;
        }
        return aliasFromClassName(packageName, componentName.getClassName());
    }

    private static String aliasFromClassName(String pkg, String className) {
        if (className == null || className.isEmpty()) {
            return null;
        }
        String prefix = pkg + ".";
        if (className.startsWith(prefix)) {
            return className.substring(prefix.length());
        }
        if (className.startsWith(".")) {
            return className.substring(1);
        }
        return className;
    }

    private static boolean isMainActivity(String alias) {
        return alias == null || alias.isEmpty() || "MainActivity".equals(alias);
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private List<String> stringList(JSArray array) throws JSONException {
        List<String> names = new ArrayList<>();
        if (array == null) {
            return names;
        }
        for (Object item : array.toList()) {
            if (item != null) {
                names.add(String.valueOf(item));
            }
        }
        return names;
    }

    private static final class LauncherAlias {

        final String alias;
        final boolean manifestEnabled;
        final boolean currentlyEnabled;

        LauncherAlias(String alias, boolean manifestEnabled, boolean currentlyEnabled) {
            this.alias = alias;
            this.manifestEnabled = manifestEnabled;
            this.currentlyEnabled = currentlyEnabled;
        }
    }

    private static final class StopCallback implements Application.ActivityLifecycleCallbacks {

        @Override
        public void onActivityStopped(Activity activity) {
            if (activity == null) {
                return;
            }
            applyPending(activity, "onStop");
        }

        @Override
        public void onActivityCreated(Activity activity, Bundle savedInstanceState) {}

        @Override
        public void onActivityStarted(Activity activity) {}

        @Override
        public void onActivityResumed(Activity activity) {}

        @Override
        public void onActivityPaused(Activity activity) {}

        @Override
        public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}

        @Override
        public void onActivityDestroyed(Activity activity) {}
    }
}
