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
   * On Android, enables that activity-alias, recreates the activity through it, then disables the other aliases. MainActivity is left unchanged. The WebView reloads.
   *
   * @since 1.0.0
   */
  change(options: IconOptions): Promise<void>;
  /**
   * Reverts the app icon to the original.
   *
   * On Android, restores each named activity-alias to its manifest enabled state and does not enable MainActivity as a launcher. The activity is recreated through the default alias when that change disables the current one, and the WebView reloads.
   *
   * @since 1.0.0
   */
  reset(options: ResetOptions): Promise<void>;

  // appIconBadgeNumber(): Promise<{value: number}>;
}
