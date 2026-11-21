//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreLocation
import SwiftUI

/// Implemented by MapLibreShim's entry point, which the app instantiates after
/// `dlopen`-ing the framework.
public protocol MapLibreShimProtocol {
    /// Routes MapLibre's logs into the app's logger. Call once after loading the shim.
    func configureLogging(_ handler: @escaping @Sendable (MapLogSeverity, String) -> Void)
    
    /// Builds the interactive map view. The app-side `MapLibreMapView` forwards every
    /// body evaluation here so SwiftUI updates flow through to the underlying map.
    func makeMapView(configuration: MapViewConfiguration) -> AnyView
    
    /// PSST (D97): renders a static image of the map on the device (the psst map proxy has no static image API).
    /// The completion handler is called on the main thread, with nil when the map couldn't be rendered.
    func makeSnapshot(styleURL: URL,
                      center: CLLocationCoordinate2D,
                      zoomLevel: Double,
                      size: CGSize,
                      completion: @escaping (UIImage?) -> Void)
}
