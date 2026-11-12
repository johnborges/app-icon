import UIKit
import WebKit
import Capacitor

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Evidence-only hook for the scratch CI branch. Absent from capacitor-9-example.
        evidenceChangeIconIfRequested()
        return true
    }

    private func evidenceChangeIconIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--evidence-change-icon"), flag + 1 < args.count else {
            return
        }
        let iconName = args[flag + 1]
        guard ["ionic", "stencil", "ionitron"].contains(iconName) else {
            NSLog("EVIDENCE_ICON_ERR rejected name \(iconName)")
            return
        }
        NSLog("EVIDENCE_ICON_REQUEST \(iconName)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.evidenceInvokeChange(iconName, attempt: 0)
        }
        for delay in [12.0, 20.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let current = UIApplication.shared.alternateIconName ?? "nil"
                NSLog("EVIDENCE_NATIVE_ICON \(current)")
            }
        }
    }

    private func evidenceInvokeChange(_ iconName: String, attempt: Int) {
        guard let bridge = evidenceBridge() else {
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.evidenceInvokeChange(iconName, attempt: attempt + 1)
                }
            } else {
                NSLog("EVIDENCE_ICON_ERR bridge not ready")
            }
            return
        }
        let js = """
        (function(){
          if (!window.Capacitor || !window.Capacitor.Plugins || !window.Capacitor.Plugins.AppIcon) { return 'wait'; }
          var disable = ['ionic','stencil','ionitron'].filter(function(n){ return n !== '\(iconName)'; });
          window.Capacitor.Plugins.AppIcon.change({name:'\(iconName)', disable: disable})
            .then(function(){ console.log('EVIDENCE_ICON_OK'); })
            .catch(function(e){ console.log('EVIDENCE_ICON_ERR ' + (e && e.message ? e.message : e)); });
          return 'called';
        })()
        """
        bridge.webView?.evaluateJavaScript(js) { result, error in
            if let error {
                NSLog("EVIDENCE_ICON_ERR eval \(error.localizedDescription)")
            }
            let value = result as? String ?? String(describing: result ?? "nil")
            NSLog("EVIDENCE_ICON_EVAL \(value)")
            if value.contains("wait"), attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.evidenceInvokeChange(iconName, attempt: attempt + 1)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let current = UIApplication.shared.alternateIconName ?? "nil"
            NSLog("EVIDENCE_NATIVE_ICON \(current)")
        }
    }

    private func evidenceBridge() -> CAPBridgeProtocol? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                if let root = window.rootViewController, let bridge = findBridge(in: root) {
                    return bridge.bridge
                }
            }
        }
        return nil
    }

    private func findBridge(in viewController: UIViewController) -> CAPBridgeViewController? {
        if let bridgeViewController = viewController as? CAPBridgeViewController {
            return bridgeViewController
        }
        for child in viewController.children {
            if let found = findBridge(in: child) {
                return found
            }
        }
        return nil
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        ApplicationDelegateProxy.shared.application(application, supportedInterfaceOrientationsFor: window)
    }
}
