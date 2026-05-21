import Foundation

enum AppResources {
    private static let bundleName = "CodexMux_CodexMux.bundle"

    static let bundle: Bundle? = {
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]

        for candidate in candidates {
            guard let bundleURL = candidate?.appendingPathComponent(bundleName),
                  let bundle = Bundle(url: bundleURL)
            else {
                continue
            }

            return bundle
        }

        return nil
    }()
}
