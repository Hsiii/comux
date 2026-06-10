import Foundation
import AppKit

enum AppResources {
    private static let bundleName = "comux_Comux.bundle"

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

        if subdirectory != nil,
           let url = Bundle.main.url(forResource: name, withExtension: ext)
        {
            return url
        }

        return self.moduleBundle?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    static func image(named name: String, withExtension ext: String? = nil, subdirectory: String? = nil) -> NSImage? {
        if let url = self.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
           let image = NSImage(contentsOf: url)
        {
            return image
        }

        let resourceName = ext.map { "\(name).\($0)" } ?? name

        if let image = Bundle.main.image(forResource: resourceName)
        {
            return image
        }

        return nil
    }
}
