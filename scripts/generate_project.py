#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project with only Python's standard library.

Run after adding/removing Swift files. No XcodeGen or downloaded dependencies.
All source paths and object identifiers are deterministic.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects: dict[str, dict] = {}


def identifier(name: str) -> str:
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def obj(object_name: str, isa: str, **fields) -> str:
    key = identifier(object_name)
    if key in objects:
        raise ValueError(f"Duplicate project object: {object_name}")
    objects[key] = {"isa": isa, **fields}
    return key


def serialize(value, level=0) -> str:
    indent = "\t" * level
    if isinstance(value, dict):
        contents = "\n".join(
            f"{indent}\t{json.dumps(str(k))} = {serialize(v, level + 1)};"
            for k, v in value.items()
        )
        return "{\n" + contents + "\n" + indent + "}"
    if isinstance(value, list):
        contents = "\n".join(f"{indent}\t{serialize(v, level + 1)}," for v in value)
        return "(\n" + contents + "\n" + indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value))


file_refs = {}
groups = {}
for folder in ("Glean", "GleanWidgets", "Tests"):
    children = []
    for file in sorted((ROOT / folder).rglob("*")):
        if file.is_dir() or ".xcassets/" in file.as_posix():
            continue
        if file.suffix not in {".swift", ".plist", ".entitlements", ".xcprivacy"}:
            continue
        path = file.relative_to(ROOT).as_posix()
        kind = {
            ".swift": "sourcecode.swift",
            ".plist": "text.plist.xml",
            ".entitlements": "text.plist.entitlements",
            ".xcprivacy": "text.xml",
        }[file.suffix]
        file_refs[path] = obj(f"file:{path}", "PBXFileReference", lastKnownFileType=kind,
                              path=file.relative_to(ROOT / folder).as_posix(), sourceTree="<group>")
        children.append(file_refs[path])
    if folder == "Glean":
        path = "Glean/Resources/Assets.xcassets"
        file_refs[path] = obj(f"file:{path}", "PBXFileReference", lastKnownFileType="folder.assetcatalog",
                              path="Resources/Assets.xcassets", sourceTree="<group>")
        children.append(file_refs[path])
    groups[folder] = obj(f"group:{folder}", "PBXGroup", children=children, path=folder, sourceTree="<group>")

products = {}
for name, extension, kind in (
    ("Glean", "app", "wrapper.application"),
    ("GleanWidgets", "appex", "wrapper.app-extension"),
    ("GleanTests", "xctest", "wrapper.cfbundle"),
):
    products[name] = obj(f"product:{name}", "PBXFileReference", explicitFileType=kind,
                         includeInIndex=0, path=f"{name}.{extension}", sourceTree="BUILT_PRODUCTS_DIR")
product_group = obj("group:Products", "PBXGroup", children=list(products.values()), name="Products", sourceTree="<group>")
main_group = obj("group:root", "PBXGroup", children=[*groups.values(), product_group], sourceTree="<group>")


def build_phase(target: str, phase: str, paths: list[str]) -> str:
    files = [obj(f"build:{target}:{phase}:{path}", "PBXBuildFile", fileRef=file_refs[path]) for path in paths]
    return obj(f"phase:{target}:{phase}", f"PBX{phase}BuildPhase", buildActionMask=2147483647,
               files=files, runOnlyForDeploymentPostprocessing=0)


def configurations(name: str, base: dict, debug: dict | None = None, release: dict | None = None) -> str:
    ids = []
    for configuration, extra in (("Debug", debug or {}), ("Release", release or {})):
        ids.append(obj(f"config:{name}:{configuration}", "XCBuildConfiguration",
                       buildSettings={**base, **extra}, name=configuration))
    return obj(f"configs:{name}", "XCConfigurationList", buildConfigurations=ids,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


project_configs = configurations("project", {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GLEAN_APP_GROUP": "group.com.example.Glean",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "2",
}, {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}, {
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "VALIDATE_PRODUCT": "YES",
})

shared_settings = {
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
}
app_configs = configurations("Glean", {**shared_settings,
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_ENTITLEMENTS": "Glean/Glean.entitlements",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Glean/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Glean",
})
widget_configs = configurations("GleanWidgets", {**shared_settings,
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "CODE_SIGN_ENTITLEMENTS": "GleanWidgets/GleanWidgets.entitlements",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "GleanWidgets/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Glean.Widgets",
    "SKIP_INSTALL": "YES",
})
test_configs = configurations("GleanTests", {**shared_settings,
    "BUNDLE_LOADER": "$(TEST_HOST)",
    "GENERATE_INFOPLIST_FILE": "YES",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Glean.Tests",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Glean.app/Glean",
})

project_id = identifier("project")
target_ids = {name: identifier(f"target:{name}") for name in products}


def dependency(source: str, destination: str) -> str:
    proxy = obj(f"proxy:{source}:{destination}", "PBXContainerItemProxy", containerPortal=project_id,
                proxyType=1, remoteGlobalIDString=target_ids[destination], remoteInfo=destination)
    return obj(f"dependency:{source}:{destination}", "PBXTargetDependency",
               target=target_ids[destination], targetProxy=proxy)


embed_file = obj("build:embed-widget", "PBXBuildFile", fileRef=products["GleanWidgets"],
                 settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]})
embed_phase = obj("phase:embed-widget", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                  dstPath="", dstSubfolderSpec=13, files=[embed_file], name="Embed App Extensions",
                  runOnlyForDeploymentPostprocessing=0)

app_sources = sorted(path for path in file_refs if path.startswith("Glean/") and path.endswith(".swift"))
widget_sources = ["GleanWidgets/GleanWidgets.swift", "Glean/Shared/WidgetStore.swift"]
test_sources = sorted(path for path in file_refs if path.startswith("Tests/") and path.endswith(".swift"))
for name, config, sources, resources, dependencies, product_type in (
    ("Glean", app_configs, app_sources, ["Glean/Resources/Assets.xcassets", "Glean/PrivacyInfo.xcprivacy"],
     [dependency("Glean", "GleanWidgets")], "com.apple.product-type.application"),
    ("GleanWidgets", widget_configs, widget_sources, ["Glean/PrivacyInfo.xcprivacy"],
     [], "com.apple.product-type.app-extension"),
    ("GleanTests", test_configs, test_sources, [],
     [dependency("GleanTests", "Glean")], "com.apple.product-type.bundle.unit-test"),
):
    phases = [build_phase(name, "Sources", sources), build_phase(name, "Frameworks", []), build_phase(name, "Resources", resources)]
    if name == "Glean":
        phases.append(embed_phase)
    obj(f"target:{name}", "PBXNativeTarget", buildConfigurationList=config, buildPhases=phases,
        buildRules=[], dependencies=dependencies, name=name, productName=name,
        productReference=products[name], productType=product_type)

obj("project", "PBXProject", attributes={
    "BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600",
    "TargetAttributes": {
        target_ids[name]: {
            "CreatedOnToolsVersion": "16.0",
            **({"SystemCapabilities": {"com.apple.ApplicationGroups.iOS": {"enabled": 1}}}
               if name != "GleanTests" else {}),
        }
        for name in products
    },
}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en",
    hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group,
    productRefGroup=product_group, projectDirPath="", projectRoot="", targets=list(target_ids.values()))

project = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id}
destination = ROOT / "Glean.xcodeproj" / "project.pbxproj"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("// !$*UTF8*$!\n" + serialize(project) + "\n")

app_id, widget_id, test_id = (target_ids[name] for name in ("Glean", "GleanWidgets", "GleanTests"))


def reference(name: str, extension: str, target_id: str) -> str:
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{name}.{extension}" BlueprintName="{name}" ReferencedContainer="container:Glean.xcodeproj"/>'


app_ref = reference("Glean", "app", app_id)
widget_ref = reference("GleanWidgets", "appex", widget_id)
test_ref = reference("GleanTests", "xctest", test_id)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{widget_ref}</BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{test_ref}</BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_path = ROOT / "Glean.xcodeproj" / "xcshareddata" / "xcschemes" / "Glean.xcscheme"
scheme_path.parent.mkdir(parents=True, exist_ok=True)
scheme_path.write_text(scheme)
print(f"Generated {destination.relative_to(ROOT)}: {len(app_sources)} app sources, {len(widget_sources)} widget sources, {len(test_sources)} test sources")
