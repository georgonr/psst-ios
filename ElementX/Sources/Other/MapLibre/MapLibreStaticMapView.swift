//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import CoreLocation
import SwiftUI

struct MapLibreStaticMapView<PinAnnotation: View>: View {
    private let coordinates: CLLocationCoordinate2D
    private let zoomLevel: Double
    private let mapURLBuilder: MapTilerURLBuilderProtocol
    private let mapTilerAttributionPlacement: MapTilerAttributionPlacement
    private let mapSize: CGSize
    private let pinAnnotationView: PinAnnotation
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var fetchAttempt = 0
    
    init(coordinates: CLLocationCoordinate2D,
         zoomLevel: Double,
         attributionPlacement: MapTilerAttributionPlacement,
         mapURLBuilder: MapTilerURLBuilderProtocol,
         mapSize: CGSize,
         @ViewBuilder pinAnnotationView: () -> PinAnnotation) {
        self.coordinates = coordinates
        self.zoomLevel = zoomLevel
        self.mapURLBuilder = mapURLBuilder
        mapTilerAttributionPlacement = attributionPlacement
        self.mapSize = mapSize
        self.pinAnnotationView = pinAnnotationView()
    }
    
    init(geoURI: GeoURI,
         mapURLBuilder: MapTilerURLBuilderProtocol,
         attributionPlacement: MapTilerAttributionPlacement = .bottomLeft,
         mapSize: CGSize,
         @ViewBuilder pinAnnotationView: () -> PinAnnotation) {
        self.init(coordinates: .init(latitude: geoURI.latitude, longitude: geoURI.longitude),
                  zoomLevel: 15,
                  attributionPlacement: attributionPlacement,
                  mapURLBuilder: mapURLBuilder,
                  mapSize: mapSize,
                  pinAnnotationView: pinAnnotationView)
    }
    
    var body: some View {
        GeometryReader { geometry in
            if let url = mapURLBuilder.staticMapTileImageURL(for: colorScheme.mapStyle,
                                                             coordinates: coordinates,
                                                             zoomLevel: zoomLevel,
                                                             size: mapSize, // temporary using a fixed size since the refresh doesn't work properly on the UITableView based timeline
                                                             attribution: mapTilerAttributionPlacement) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholderImage
                    case .success(let image):
                        ZStack {
                            image
                                .resizable()
                                .scaledToFill()
                            pinAnnotationView
                        }
                    case .failure(let error):
                        let _ = MXLog.error("Failed retrieving tile with error: \(error.localizedDescription)")
                        errorView
                    @unknown default:
                        EmptyView()
                    }
                }
                .position(x: geometry.frame(in: .local).midX, y: geometry.frame(in: .local).midY)
                .id(fetchAttempt)
            } else if let styleURL = mapURLBuilder.interactiveMapURL(for: colorScheme.mapStyle) {
                // PSST (D97): no static image API on the psst map proxy — render the preview on the device.
                PsstMapSnapshotView(styleURL: styleURL,
                                    coordinates: coordinates,
                                    zoomLevel: zoomLevel,
                                    mapSize: mapSize,
                                    attributionAlignment: mapTilerAttributionPlacement.psstAlignment,
                                    pinAnnotationView: pinAnnotationView,
                                    placeholder: placeholderImage)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                placeholderImage
            }
        }
    }
    
    private var placeholderImage: some View {
        Image(asset: Asset.Images.mapBlurred)
            .resizable()
            .scaledToFill()
    }
    
    private var errorView: some View {
        Button {
            fetchAttempt += 1
        } label: {
            placeholderImage
                .overlay {
                    VStack(spacing: 0) {
                        CompoundIcon(\.restart)
                        Text(L10n.actionStaticMapLoad)
                    }
                }
        }
    }
}

// MARK: - PSST (D97): on-device static map previews

/// The attribution the psst maps (OpenFreeMap / OpenStreetMap) require wherever the map is shown.
enum PsstMapAttribution {
    static let text = "© OpenMapTiles © OpenStreetMap contributors"
}

struct PsstMapAttributionLabel: View {
    var body: some View {
        Text(PsstMapAttribution.text)
            .font(.system(size: 9))
            .foregroundColor(.compound.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.compound.bgCanvasDefault.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            .padding(4)
            .accessibilityLabel(PsstMapAttribution.text)
    }
}

private struct PsstMapSnapshotView<PinAnnotation: View, Placeholder: View>: View {
    let styleURL: URL
    let coordinates: CLLocationCoordinate2D
    let zoomLevel: Double
    let mapSize: CGSize
    let attributionAlignment: Alignment
    let pinAnnotationView: PinAnnotation
    let placeholder: Placeholder
    
    @State private var image: UIImage?
    @State private var failed = false
    @State private var fetchAttempt = 0
    
    private var cacheKey: String {
        "\(styleURL.absoluteString)|\(coordinates.latitude)|\(coordinates.longitude)|\(zoomLevel)|\(Int(mapSize.width))x\(Int(mapSize.height))|\(fetchAttempt)"
    }
    
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                pinAnnotationView
            } else if failed {
                Button {
                    failed = false
                    fetchAttempt += 1
                } label: {
                    placeholder
                        .overlay {
                            VStack(spacing: 0) {
                                CompoundIcon(\.restart)
                                Text(L10n.actionStaticMapLoad)
                            }
                        }
                }
            } else {
                placeholder
            }
        }
        .clipped()
        .overlay(alignment: attributionAlignment) {
            PsstMapAttributionLabel()
        }
        .task(id: cacheKey) {
            if let cached = PsstMapSnapshotCache.shared.image(for: cacheKey) {
                image = cached
                return
            }
            let snapshot = await PsstMapSnapshotCache.shared.snapshot(key: cacheKey,
                                                                      styleURL: styleURL,
                                                                      coordinates: coordinates,
                                                                      zoomLevel: zoomLevel,
                                                                      size: mapSize)
            image = snapshot
            failed = snapshot == nil
        }
    }
}

@MainActor
private final class PsstMapSnapshotCache {
    static let shared = PsstMapSnapshotCache()
    
    private let cache = NSCache<NSString, UIImage>()
    
    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    
    func snapshot(key: String, styleURL: URL, coordinates: CLLocationCoordinate2D, zoomLevel: Double, size: CGSize) async -> UIImage? {
        guard let shim = MapLibreLoader.shim, size.width > 0, size.height > 0 else { return nil }
        
        let image: UIImage? = await withCheckedContinuation { continuation in
            shim.makeSnapshot(styleURL: styleURL, center: coordinates, zoomLevel: zoomLevel, size: size) { image in
                continuation.resume(returning: image)
            }
        }
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}

private extension MapTilerAttributionPlacement {
    var psstAlignment: Alignment {
        switch self {
        case .bottomLeft: .bottomLeading
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomRight, .hidden: .bottomTrailing
        }
    }
}

private extension ColorScheme {
    var mapStyle: MapTilerStyle {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        @unknown default:
            return .light
        }
    }
}

struct MapLibreStaticMapView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        MapLibreStaticMapView(coordinates: CLLocationCoordinate2D(),
                              zoomLevel: 15,
                              attributionPlacement: .bottomLeft,
                              mapURLBuilder: MapTilerURLBuilderMock(),
                              mapSize: .init(width: 300, height: 200)) {
            Image(systemName: "mappin.circle.fill")
                .padding(.bottom, 35)
        }
    }
}

private struct MapTilerURLBuilderMock: MapTilerURLBuilderProtocol {
    func interactiveMapURL(for style: MapTilerStyle) -> URL? {
        nil
    }
    
    func staticMapTileImageURL(for style: MapTilerStyle,
                               coordinates: CLLocationCoordinate2D,
                               zoomLevel: Double,
                               size: CGSize,
                               attribution: MapTilerAttributionPlacement) -> URL? {
        switch style {
        case .light:
            return URL(string: "https://www.maptiler.com/img/cloud/home/map5.webp")
        case .dark:
            return URL(string: "https://www.maptiler.com/img/cloud/home/map6.webp")
        }
    }
}
