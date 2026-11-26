export interface IconOptions {
  /**
   * Name of alternate icon to set
   */
  name: string;
  /**
   * Name of icons to disable. This is not used for iOS, but required for Android.
   * @since 3.1.0
   */
  disable?: string[];
  /**
   * Flag controlling the in app notification which shows after icon is changed. (iOS)
   * @deprecated This parameter is ignored as the system notification will always be shown starting on iOS 26.
   */
  suppressNotification?: boolean;
}

export interface ResetOptions {
  /**
   * Flag controlling the in app notification which shows after icon is changed (iOS).
   * @deprecated This parameter is ignored as the system notification will always be shown starting on iOS 26.
   */
  suppressNotification?: boolean;

  /**
   * Name of icons to disable. This is not used for iOS, but required for Android.
   * @since 3.1.1
   */
  disable?: string[];
}

export interface AppIconPlugin {
  /**
   * Checks if changing the app icon is supported. (iOS only)
   * @since 1.0.0
   */
  isSupported(): Promise<{ value: boolean }>;
  /**
   * Gets the name of the currently set alternate icon.
   *
   * On iOS, returns null when the original icon is set. On Android, returns the enabled launcher activity-alias, or null when no launcher entry can be resolved. It does not throw when the package has no launch intent.
   *
   * @since 1.0.0
   */
  getName(): Promise<{ value: string | null }>;
  /**
   * Changes the app icon to the specified alternate.
   *
   * On Android, enables that activity-alias immediately and does not relaunch the activity. Aliases in disable stay enabled until the host activity stops, so the launcher can briefly show more than one icon while the app is in the foreground. On stop they are disabled with DONT_KILL_APP. The pending disable is stored and applied on the next start if the process dies first. MainActivity is left unchanged. The WebView stays loaded for the rest of the foreground session. Disabling the alias that launched the current task finishes that activity in the background, so the next open loads a fresh WebView.
   *
   * @since 1.0.0
   */
  change(options: IconOptions): Promise<void>;
  /**
   * Reverts the app icon to the original.
   *
   * On Android, the default alias is the manifest-enabled launcher activity-alias reported by PackageManager (ActivityInfo.enabled), and the current alias comes from getComponentEnabledSetting. The default alias is enabled immediately. Every other named alias is restored to its manifest enabled state when the host activity stops, which leaves one launcher. MainActivity is not enabled or disabled. The WebView stays loaded in the foreground. The next open loads a fresh WebView if that background restore finishes the activity.
   *
   * @since 1.0.0
   */
  reset(options: ResetOptions): Promise<void>;

  // appIconBadgeNumber(): Promise<{value: number}>;
}
