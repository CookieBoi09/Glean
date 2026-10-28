# Glean

A native iPad studio for little 3D worlds. Rotate a model by tilting the iPad, drag and pinch to explore, choose a photo background, and save the view to small, medium, or large Home Screen widgets.

**WidgetKit does not expose live motion sensors or continuous 3D rendering.** Tilt and touch interaction work in the app. Widgets show the last saved render and open the studio when tapped. Reload timing is controlled by iPadOS. All widget sizes currently share one saved view.

## Run on an iPad

Requires a Mac with **Xcode 16 or later**, iPadOS 17+, and an Apple development team with App Groups available for device signing. There are no third-party runtime packages, backend services, API keys, or downloaded model dependencies.

1. Open `Glean.xcodeproj` in Xcode and select the **Glean** scheme.
2. Under Signing & Capabilities, select your team for **Glean** and **GleanWidgets**. Replace the example bundle identifiers with unique identifiers; the extension identifier must start with the app identifier, for example `com.yourcompany.Glean.Widgets`.
3. Register one App Group (for example `group.com.yourcompany.Glean`) and enable it for **both** targets. Set the project build setting **GLEAN_APP_GROUP** to that exact identifier. Both Info.plists and entitlements use this setting. Keep the two targets on the same team.
4. Choose a physical iPad and run. The original procedural Among Us–style crewmate loads without importing anything. It is a test asset, not an official game asset.
5. Enable **Follow my iPad**, hold the device comfortably, and tap **Recenter model**. Drag and accessible rotation sliders also work without sensors. Pinch or use the zoom slider to zoom.
6. Choose a photo through the system Photos picker. Glean only receives the selected image; full photo-library permission is unnecessary.
7. Tap **Save to widgets**. On the Home Screen, touch and hold, open the widget gallery, search for **Glean**, and add any of its three sizes. Tap a widget to reopen the app.

The Simulator supports the viewer and touch controls, but not physical device motion. Widget saving requires the shared App Group container; a useful error appears if signing/capabilities are missing. No credentials should be put in source files.

## Model importing

| Format | Loader / scope |
| --- | --- |
| USDZ, USD, USDA, USDC | Apple's native SceneKit scene loader; support depends on the iPadOS version and asset contents |
| SCN, DAE | SceneKit scenes / Collada |
| OBJ, STL, PLY, ABC | Model I/O, when `MDLAsset.canImportFileExtension` reports availability on the device |
| GLB, glTF 2.0 | Bundled static-mesh loader, with no external dependencies |

Use **Import a 3D model** to select a self-contained file. For OBJ with MTL/textures, glTF with external buffers/textures, or other multi-file assets, select the **containing folder** instead. Prefer exactly one model at the folder's top level, with its companion resources underneath. Files are copied into app-owned storage before access to the Files provider ends. A failed import leaves the current model intact.

The glTF loader handles triangle geometry, node transforms, mesh instances, generated normals, UV0, base-color textures and scalar metallic/roughness factors. Animated/skinned/morphing models, sparse accessors, Draco/meshopt compression, and required extensions are rejected with a message. Other material maps (normal, occlusion, emissive, metallic/roughness textures), vertex colors, optional extensions, and texture transforms are not implemented; their shading is approximate. Export a static, uncompressed mesh or use USDZ for broader native support. FBX and `.blend` projects need conversion first.

Limits: 100 MiB per model file; 200 MiB and 512 files per imported folder. The glTF loader also bounds buffers, geometry, hierarchy depth, and texture memory. It does not fetch remote resources or permit external resources to escape the model folder. Photo decoding is bounded to 2048 pixels and widget renders to 1200 pixels. Imported models and the selected background remain local. Old imports are retained in app storage; removing the app clears them.

## Build and checks

On a Mac with Xcode selected:

```sh
xcodebuild -list -project Glean.xcodeproj
xcodebuild -project Glean.xcodeproj -scheme Glean \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -showdestinations -project Glean.xcodeproj -scheme Glean
# Substitute an installed iPad simulator's identifier from the command above.
xcodebuild -project Glean.xcodeproj -scheme Glean \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  CODE_SIGNING_ALLOWED=NO test
```

XCTest covers scene construction and normalization, import validation and preservation, GLB/glTF parsing and rejection of malformed resources, and widget serialization/corruption handling. Test fixtures are generated locally by the tests.

Before shipping, test on an actual iPad: portrait and landscape tilt/recenter, app background/foreground, every supported import format you intend to distribute, a folder with textures, photo selection/cancellation, relaunch persistence, widget saving in each family, and widget tap navigation. Verify signing and App Group access for both targets. Check larger Dynamic Type settings and VoiceOver; sliders provide alternatives to gestures.

This implementation was authored in a Linux cloud workspace without Xcode or Apple SDKs. Swift syntax parsing and project/resource structure can be checked here; iOS compilation, XCTest execution, Metal rendering, motion behavior, and installed widgets **have not been verified on-device**.

## Layout

- `Glean/App`: SwiftUI studio, gestures, photo selection and snapshot composition.
- `Glean/Rendering`: SceneKit scenes, Core Motion, native imports and the glTF loader.
- `Glean/Shared`: atomic App Group snapshot storage shared by the app and extension.
- `GleanWidgets`: WidgetKit layouts and deep links.
- `Tests`: XCTest regression tests.
- `scripts/generate_project.py`: regenerates the checked-in project after adding/removing source files. No dependency installation is needed. It restores the example build settings, so regenerate before customizing signing or reapply your bundle IDs, team, and App Group afterward.

Each cloud task is already isolated. Continue in this checkout; do not create another Git worktree unless explicitly requested.
