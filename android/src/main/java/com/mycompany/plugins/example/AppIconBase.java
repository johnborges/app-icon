package com.mycompany.plugins.example;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Application;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.XmlResourceParser;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import com.getcapacitor.JSArray;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONException;
import org.xmlpull.v1.XmlPullParser;

public class AppIconBase {

    private static final String TAG = "AppIconBase";
    private static final String ANDROID_NS = "http://schemas.android.com/apk/res/android";
    private static final Object LOCK = new Object();
    private static Pending pending;
    private static Application.ActivityLifecycleCallbacks callbacks;
    private static Application pendingApp;
    private static PackageManager pendingPm;
    private static String pendingPackageName;
    private static int relaunchedIdentity;
    private static boolean relaunchReady;

    private final Activity activity;
    private final Context context;
    private final String packageName;
    private final PackageManager pm;

    public AppIconBase(Activity activity, Context context) {
        this.activity = activity;
        this.context = context;
        this.packageName = context.getPackageName();
        this.pm = context.getApplicationContext().getPackageManager();
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
        // Enable the new alias and relaunch through it before disabling the old
        // ones. The resumed activity then belongs to an enabled component, so
        // Android does not finish it for disabled-package, and one launcher remains.
        // MainActivity is never enabled or disabled; it is not a launcher.
        if (enableName == null || enableName.isEmpty() || "MainActivity".equals(enableName)) {
            Log.e(TAG, "refusing icon name " + enableName);
            return;
        }
        try {
            List<String> names = stringList(disableNames);
            setState(enableName, PackageManager.COMPONENT_ENABLED_STATE_ENABLED);
            Log.i(TAG, "enabled " + enableName);
            relaunchThenApply(enableName, names, false);
        } catch (JSONException ex) {
            Log.e(TAG, "change failed to read disable list", ex);
        }
    }

    public void reset(JSArray disableNames) {
        try {
            List<String> names = stringList(disableNames);
            String defaultAlias = manifestDefaultLauncherAlias();
            String current = shortName(currentLauncher());
            Log.i(TAG, "reset default=" + defaultAlias + " current=" + current);
            if (defaultAlias == null || "MainActivity".equals(defaultAlias)) {
                Log.e(TAG, "no manifest default launcher alias; leaving the current launcher enabled");
                for (String value : names) {
                    if (value == null || value.isEmpty() || "MainActivity".equals(value) || value.equals(current)) {
                        continue;
                    }
                    setState(value, PackageManager.COMPONENT_ENABLED_STATE_DEFAULT);
                }
                return;
            }
            setState(defaultAlias, PackageManager.COMPONENT_ENABLED_STATE_ENABLED);
            if (defaultAlias.equals(current)) {
                restoreDefaults(names, defaultAlias);
                return;
            }
            relaunchThenApply(defaultAlias, names, true);
        } catch (JSONException ex) {
            Log.e(TAG, "reset failed to read disable list", ex);
        }
    }

    private void relaunchThenApply(String alias, List<String> names, boolean restoreDefaults) {
        Application app = (Application) context.getApplicationContext();
        synchronized (LOCK) {
            clearCallbacksLocked(app);
            pending = new Pending(names, alias, restoreDefaults);
            relaunchedIdentity = 0;
            relaunchReady = false;
            pendingApp = app;
            pendingPm = pm;
            pendingPackageName = packageName;
            callbacks = new RelaunchWatcher();
            app.registerActivityLifecycleCallbacks(callbacks);
        }
        try {
            startAlias(alias);
        } catch (RuntimeException ex) {
            Log.e(TAG, "relaunch failed; not disabling the running alias", ex);
            synchronized (LOCK) {
                pending = null;
                clearCallbacksLocked(app);
            }
            return;
        }
        scheduleCheck(app, 0);
    }

    private static void scheduleCheck(Application app, int attempt) {
        new Handler(Looper.getMainLooper()).postDelayed(
            () -> {
                boolean ready;
                synchronized (LOCK) {
                    ready = relaunchReady;
                    if (pending == null) {
                        return;
                    }
                }
                if (ready) {
                    applyPending("timer-after-resume");
                    return;
                }
                if (attempt >= 5) {
                    Log.e(TAG, "relaunch did not resume the new alias; leaving the running alias enabled");
                    synchronized (LOCK) {
                        pending = null;
                        clearCallbacksLocked(app);
                    }
                    return;
                }
                scheduleCheck(app, attempt + 1);
            },
            300
        );
    }

    private static void applyPending(String reason) {
        Pending action;
        PackageManager manager;
        String pkg;
        synchronized (LOCK) {
            action = pending;
            pending = null;
            manager = pendingPm;
            pkg = pendingPackageName;
            clearCallbacksLocked(pendingApp);
        }
        if (action == null || manager == null || pkg == null) {
            return;
        }
        Log.i(TAG, "apply alias state reason=" + reason + " keep=" + action.keepAlias + " restore=" + action.restoreDefaults);
        if (action.restoreDefaults) {
            restoreDefaults(manager, pkg, action.names, action.keepAlias);
        } else {
            disableOthers(manager, pkg, action.names, action.keepAlias);
        }
    }

    private static void disableOthers(PackageManager manager, String pkg, List<String> names, String keepAlias) {
        for (String value : names) {
            if (value == null || value.isEmpty() || "MainActivity".equals(value) || value.equals(keepAlias)) {
                continue;
            }
            setState(manager, pkg, value, PackageManager.COMPONENT_ENABLED_STATE_DISABLED);
            Log.i(TAG, "disabled " + value);
        }
    }

    private void restoreDefaults(List<String> names, String defaultAlias) {
        restoreDefaults(pm, packageName, names, defaultAlias);
    }

    private static void restoreDefaults(PackageManager manager, String pkg, List<String> names, String defaultAlias) {
        for (String value : names) {
            if (value == null || value.isEmpty() || "MainActivity".equals(value)) {
                continue;
            }
            setState(manager, pkg, value, PackageManager.COMPONENT_ENABLED_STATE_DEFAULT);
            Log.i(TAG, "defaulted " + value);
        }
        if (defaultAlias != null && !"MainActivity".equals(defaultAlias)) {
            setState(manager, pkg, defaultAlias, PackageManager.COMPONENT_ENABLED_STATE_DEFAULT);
            Log.i(TAG, "defaulted " + defaultAlias);
        }
    }

    private void setState(String alias, int state) {
        setState(pm, packageName, alias, state);
    }

    private static void setState(PackageManager manager, String pkg, String alias, int state) {
        manager.setComponentEnabledSetting(new ComponentName(pkg, pkg + "." + alias), state, PackageManager.DONT_KILL_APP);
    }

    private void startAlias(String alias) {
        ComponentName component = new ComponentName(packageName, packageName + "." + alias);
        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.setComponent(component);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        Context launchContext = activity != null ? activity : context.getApplicationContext();
        launchContext.startActivity(intent);
        Log.i(TAG, "relaunched component=" + component.flattenToShortString());
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
        List<ResolveInfo> matches = pm.queryIntentActivities(query, 0);
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
        String name = componentName.getShortClassName();
        if (name == null) {
            return null;
        }
        if (name.startsWith(".")) {
            return name.substring(1);
        }
        String prefix = packageName + ".";
        if (name.startsWith(prefix)) {
            return name.substring(prefix.length());
        }
        return name;
    }

    private String manifestDefaultLauncherAlias() {
        XmlResourceParser parser = null;
        try {
            parser = context.getAssets().openXmlResourceParser("AndroidManifest.xml");
            boolean inAlias = false;
            String aliasName = null;
            boolean aliasEnabled = true;
            boolean hasLauncher = false;
            int event = parser.getEventType();
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG) {
                    String tag = parser.getName();
                    if ("activity-alias".equals(tag)) {
                        inAlias = true;
                        aliasName = attr(parser, "name");
                        aliasEnabled = parser.getAttributeBooleanValue(ANDROID_NS, "enabled", true);
                        hasLauncher = false;
                    } else if (inAlias && "category".equals(tag)) {
                        if ("android.intent.category.LAUNCHER".equals(attr(parser, "name"))) {
                            hasLauncher = true;
                        }
                    }
                } else if (event == XmlPullParser.END_TAG && "activity-alias".equals(parser.getName())) {
                    if (inAlias && aliasEnabled && hasLauncher) {
                        String alias = aliasFromManifestName(aliasName);
                        if (alias != null && !"MainActivity".equals(alias)) {
                            return alias;
                        }
                    }
                    inAlias = false;
                }
                event = parser.next();
            }
        } catch (Exception ex) {
            Log.e(TAG, "manifest default alias lookup failed", ex);
        } finally {
            if (parser != null) {
                parser.close();
            }
        }
        return null;
    }

    private String attr(XmlResourceParser parser, String name) {
        String value = parser.getAttributeValue(ANDROID_NS, name);
        if (value != null) {
            return value;
        }
        return parser.getAttributeValue(null, name);
    }

    private String aliasFromManifestName(String manifestName) {
        if (manifestName == null || manifestName.isEmpty()) {
            return null;
        }
        if (manifestName.startsWith(".")) {
            return manifestName.substring(1);
        }
        String prefix = packageName + ".";
        if (manifestName.startsWith(prefix)) {
            return manifestName.substring(prefix.length());
        }
        return manifestName;
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

    private static void clearCallbacksLocked(Application app) {
        if (app != null && callbacks != null) {
            app.unregisterActivityLifecycleCallbacks(callbacks);
        }
        callbacks = null;
    }

    private static final class Pending {

        final List<String> names;
        final String keepAlias;
        final boolean restoreDefaults;

        Pending(List<String> names, String keepAlias, boolean restoreDefaults) {
            this.names = names;
            this.keepAlias = keepAlias;
            this.restoreDefaults = restoreDefaults;
        }
    }

    private static final class RelaunchWatcher implements Application.ActivityLifecycleCallbacks {

        @Override
        public void onActivityCreated(Activity activity, Bundle savedInstanceState) {
            if (!isOurPackage(activity)) {
                return;
            }
            synchronized (LOCK) {
                relaunchedIdentity = System.identityHashCode(activity);
            }
            ComponentName intentComponent = activity.getIntent() == null ? null : activity.getIntent().getComponent();
            Log.i(TAG, "created component=" + activity.getComponentName() + " intentComponent=" + intentComponent);
        }

        @Override
        public void onActivityResumed(Activity activity) {
            if (!isOurPackage(activity)) {
                return;
            }
            boolean created;
            synchronized (LOCK) {
                created = relaunchedIdentity != 0 && relaunchedIdentity == System.identityHashCode(activity);
                if (created) {
                    relaunchReady = true;
                }
            }
            if (!created) {
                return;
            }
            ComponentName intentComponent = activity.getIntent() == null ? null : activity.getIntent().getComponent();
            Log.i(TAG, "resumed component=" + activity.getComponentName() + " intentComponent=" + intentComponent);
            applyPending("onResume");
        }

        private boolean isOurPackage(Activity activity) {
            if (activity == null) {
                return false;
            }
            String pkg;
            synchronized (LOCK) {
                pkg = pendingPackageName;
            }
            return pkg != null && pkg.equals(activity.getPackageName());
        }

        @Override
        public void onActivityStarted(Activity activity) {}

        @Override
        public void onActivityPaused(Activity activity) {}

        @Override
        public void onActivityStopped(Activity activity) {}

        @Override
        public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}

        @Override
        public void onActivityDestroyed(Activity activity) {}
    }
}
