//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreLocation
import MapLibre
import MapLibreInterface
import SwiftUI

/// The shim's entry point: the app looks this class up by name through the ObjC runtime
/// after `dlopen`-ing the framework, keeping MapLibre off the app's launch path.
@objc(MapLibreShim)
public final class MapLibreShim: NSObject, MapLibreShimProtocol {
    public func configureLogging(_ handler: @escaping @Sendable (MapLogSeverity, String) -> Void) {
        MLNLoggingConfiguration.shared.loggingLevel = .debug
        MLNLoggingConfiguration.shared.handler = { loggingLevel, _, _, message in
            switch loggingLevel {
            case .error:
                handler(.error, message)
            case .warning:
                handler(.warning, message)
            case .info:
                handler(.info, message)
            case .debug:
                handler(.debug, message)
            case .verbose:
                handler(.verbose, message)
            default:
                break
            }
        }
    }
    
    public func makeMapView(configuration: MapViewConfiguration) -> AnyView {
        AnyView(MapLibreMapView(configuration: configuration))
    }
    
    /// Snapshotters must stay alive until they complete.
    private var activeSnapshotters: [ObjectIdentifier: MLNMapSnapshotter] = [:]
    
    public func makeSnapshot(styleURL: URL,
                             center: CLLocationCoordinate2D,
                             zoomLevel: Double,
                             size: CGSize,
                             completion: @escaping (UIImage?) -> Void) {
        let camera = MLNMapCamera()
        camera.centerCoordinate = center
        let options = MLNMapSnapshotOptions(styleURL: styleURL, camera: camera, size: size)
        options.zoomLevel = zoomLevel
        
        let snapshotter = MLNMapSnapshotter(options: options)
        let id = ObjectIdentifier(snapshotter)
        activeSnapshotters[id] = snapshotter
        snapshotter.start { [weak self] snapshot, _ in
            completion(snapshot?.image)
            self?.activeSnapshotters[id] = nil
        }
    }
}
