import Foundation

enum AppResources {
    private static let bundleName = "CodexMux_CodexMux.bundle"

    private static let moduleBundle: Bundle? = {
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

    static func url(forResource name: String, withExtension ext: String?, subdirectory: String? = nil) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }

        return self.moduleBundle?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}
