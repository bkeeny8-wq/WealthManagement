#!/usr/bin/env python3
"""Generate WealthPolicyDesk.xcodeproj with Framework + Example app targets.

Mirrors the StructuredNotesDesk project layout: a framework target that holds
the engine, models, seed data, design system, teaching layer and views, plus a
tiny host app that does `import WealthPolicyDesk` -> `DeskView()`.

Re-run this whenever the framework file list below changes.
"""

from __future__ import annotations

import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROJ = ROOT / "WealthPolicyDesk.xcodeproj"
PROJ.mkdir(exist_ok=True)


def uid() -> str:
    return uuid.uuid4().hex[:24].upper()


IDS = {
    "project": uid(),
    "framework_target": uid(),
    "app_target": uid(),
    "framework_product": uid(),
    "app_product": uid(),
    "sources_group": uid(),
    "framework_group": uid(),
    "example_group": uid(),
    "products_group": uid(),
    "assets_ref": uid(),
    "framework_sources": uid(),
    "framework_frameworks": uid(),
    "framework_resources": uid(),
    "framework_headers": uid(),
    "app_sources": uid(),
    "app_frameworks": uid(),
    "app_resources": uid(),
    "project_config_list": uid(),
    "framework_config_list": uid(),
    "app_config_list": uid(),
    "project_debug": uid(),
    "project_release": uid(),
    "framework_debug": uid(),
    "framework_release": uid(),
    "app_debug": uid(),
    "app_release": uid(),
    "framework_dep": uid(),
    "embed_phase": uid(),
    "copy_framework": uid(),
}

# The framework sources, in reading order. Compilation order is irrelevant in
# Swift; this ordering is purely for the Xcode navigator.
framework_files = [
    # foundation
    "Units.swift",
    # ported domain model (mirrors src/*.ts)
    "PolicyModel.swift",
    "HouseholdModel.swift",
    "TaxModel.swift",
    "FixedIncomeModel.swift",
    "ExposureModel.swift",
    "LayerModel.swift",
    # seeded instances + sample household
    "Seed.swift",
    # entrance questionnaire (raw answers + intake→Household builder)
    "IntakeModel.swift",
    "PracticeMetadata.swift",
    # book of business (multi-client CRM store + interchange export)
    "Book.swift",
    # the evaluation engine (implements the declared/implied pure functions)
    "Engine.swift",
    "EngineAnalyses.swift",
    "AllocationSolver.swift",
    "RiskScale.swift",
    "MacroModel.swift",
    "MacroIndicators.swift",
    "TacticalModel.swift",
    "TacticalTilts.swift",
    "CapitalMarketModel.swift",
    "CapitalMarketRisk.swift",
    "FrontierModel.swift",
    "ExposureLookthrough.swift",
    "FactorLookthrough.swift",
    "RebalanceModel.swift",
    "ShortfallModel.swift",
    "WealthGlideModel.swift",
    "Decumulation.swift",
    "Resilience.swift",
    "Planning.swift",
    # design system + teaching copy
    "Theme.swift",
    "Components.swift",
    "Teach.swift",
    # views
    "IntakeView.swift",
    "RosterView.swift",
    "DeskView.swift",
    "EconView.swift",
    "BalanceSheetTab.swift",
    "RequiredReturnTab.swift",
    "ResilienceTab.swift",
    "AllocationTab.swift",
    "RiskScaleTab.swift",
    "MacroTab.swift",
    "SentimentTab.swift",
    "CapitalMarketTab.swift",
    "FrontierTab.swift",
    "ExposureTab.swift",
    "RebalanceTab.swift",
    "PlanningTab.swift",
    "ConstraintsTab.swift",
    "TaxTab.swift",
    "DecumulationTab.swift",
    "DispositionTab.swift",
    "TiltsTab.swift",
    "LearnTab.swift",
]

header_name = "WealthPolicyDesk.h"

file_ids = {name: uid() for name in framework_files}
file_ids[header_name] = uid()
file_ids["WealthPolicyDeskApp.swift"] = uid()
file_ids["Info.plist"] = uid()

# Build file IDs (PBXBuildFile)
bf = {name: uid() for name in framework_files}
bf["app_main"] = uid()
bf["link_framework"] = uid()
bf["embed_framework"] = uid()
bf["header"] = uid()
bf["assets"] = uid()

framework_build_files = "\n".join(
    f"\t\t{bf[n]} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ids[n]} /* {n} */; }};"
    for n in framework_files
)
framework_build_files += (
    f"\n\t\t{bf['header']} /* {header_name} in Headers */ = {{isa = PBXBuildFile; "
    f"fileRef = {file_ids[header_name]} /* {header_name} */; settings = {{ATTRIBUTES = (Public, ); }}; }};"
)

file_refs = "\n".join(
    f"\t\t{file_ids[n]} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = \"<group>\"; }};"
    for n in framework_files
)
file_refs += (
    f"\n\t\t{file_ids[header_name]} /* {header_name} */ = {{isa = PBXFileReference; "
    f"lastKnownFileType = sourcecode.c.h; path = {header_name}; sourceTree = \"<group>\"; }};"
)

framework_source_children = "\n".join(f"\t\t\t\t{file_ids[n]} /* {n} */," for n in framework_files)
framework_source_children += f"\n\t\t\t\t{file_ids[header_name]} /* {header_name} */,"
framework_sources_build = "\n".join(f"\t\t\t\t{bf[n]} /* {n} in Sources */," for n in framework_files)

pbxproj = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{framework_build_files}
		{bf["app_main"]} /* WealthPolicyDeskApp.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ids["WealthPolicyDeskApp.swift"]} /* WealthPolicyDeskApp.swift */; }};
		{bf["link_framework"]} /* WealthPolicyDesk.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {IDS["framework_product"]} /* WealthPolicyDesk.framework */; }};
		{bf["embed_framework"]} /* WealthPolicyDesk.framework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {IDS["framework_product"]} /* WealthPolicyDesk.framework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};
		{bf["assets"]} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {IDS["assets_ref"]} /* Assets.xcassets */; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		{IDS["framework_dep"]} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {IDS["project"]} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {IDS["framework_target"]};
			remoteInfo = WealthPolicyDesk;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
		{IDS["embed_phase"]} /* Embed Frameworks */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 10;
			files = (
				{bf["embed_framework"]} /* WealthPolicyDesk.framework in Embed Frameworks */,
			);
			name = "Embed Frameworks";
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
{file_refs}
		{file_ids["WealthPolicyDeskApp.swift"]} /* WealthPolicyDeskApp.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WealthPolicyDeskApp.swift; sourceTree = "<group>"; }};
		{file_ids["Info.plist"]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{IDS["assets_ref"]} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};
		{IDS["framework_product"]} /* WealthPolicyDesk.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = WealthPolicyDesk.framework; sourceTree = BUILT_PRODUCTS_DIR; }};
		{IDS["app_product"]} /* WealthPolicyDeskExample.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = WealthPolicyDeskExample.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{IDS["framework_frameworks"]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{IDS["app_frameworks"]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{bf["link_framework"]} /* WealthPolicyDesk.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{IDS["sources_group"]} = {{
			isa = PBXGroup;
			children = (
				{IDS["framework_group"]} /* WealthPolicyDesk */,
				{IDS["example_group"]} /* Example */,
				{IDS["products_group"]} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{IDS["framework_group"]} /* WealthPolicyDesk */ = {{
			isa = PBXGroup;
			children = (
{framework_source_children}
			);
			name = WealthPolicyDesk;
			path = Sources/WealthPolicyDesk;
			sourceTree = "<group>";
		}};
		{IDS["example_group"]} /* Example */ = {{
			isa = PBXGroup;
			children = (
				{file_ids["WealthPolicyDeskApp.swift"]} /* WealthPolicyDeskApp.swift */,
				{IDS["assets_ref"]} /* Assets.xcassets */,
				{file_ids["Info.plist"]} /* Info.plist */,
			);
			path = Example;
			sourceTree = "<group>";
		}};
		{IDS["products_group"]} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{IDS["framework_product"]} /* WealthPolicyDesk.framework */,
				{IDS["app_product"]} /* WealthPolicyDeskExample.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXHeadersBuildPhase section */
		{IDS["framework_headers"]} /* Headers */ = {{
			isa = PBXHeadersBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{bf["header"]} /* {header_name} in Headers */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXHeadersBuildPhase section */

/* Begin PBXNativeTarget section */
		{IDS["framework_target"]} /* WealthPolicyDesk */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {IDS["framework_config_list"]} /* Build configuration list for PBXNativeTarget "WealthPolicyDesk" */;
			buildPhases = (
				{IDS["framework_headers"]} /* Headers */,
				{IDS["framework_sources"]} /* Sources */,
				{IDS["framework_frameworks"]} /* Frameworks */,
				{IDS["framework_resources"]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = WealthPolicyDesk;
			productName = WealthPolicyDesk;
			productReference = {IDS["framework_product"]} /* WealthPolicyDesk.framework */;
			productType = "com.apple.product-type.framework";
		}};
		{IDS["app_target"]} /* WealthPolicyDeskExample */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {IDS["app_config_list"]} /* Build configuration list for PBXNativeTarget "WealthPolicyDeskExample" */;
			buildPhases = (
				{IDS["app_sources"]} /* Sources */,
				{IDS["app_frameworks"]} /* Frameworks */,
				{IDS["app_resources"]} /* Resources */,
				{IDS["embed_phase"]} /* Embed Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				{IDS["copy_framework"]} /* PBXTargetDependency */,
			);
			name = WealthPolicyDeskExample;
			productName = WealthPolicyDeskExample;
			productReference = {IDS["app_product"]} /* WealthPolicyDeskExample.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{IDS["project"]} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {{
					{IDS["framework_target"]} = {{
						CreatedOnToolsVersion = 26.0;
					}};
					{IDS["app_target"]} = {{
						CreatedOnToolsVersion = 26.0;
					}};
				}};
			}};
			buildConfigurationList = {IDS["project_config_list"]} /* Build configuration list for PBXProject "WealthPolicyDesk" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {IDS["sources_group"]};
			productRefGroup = {IDS["products_group"]} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{IDS["framework_target"]} /* WealthPolicyDesk */,
				{IDS["app_target"]} /* WealthPolicyDeskExample */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{IDS["framework_resources"]} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{IDS["app_resources"]} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{bf["assets"]} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{IDS["framework_sources"]} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{framework_sources_build}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{IDS["app_sources"]} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{bf["app_main"]} /* WealthPolicyDeskApp.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		{IDS["copy_framework"]} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {IDS["framework_target"]} /* WealthPolicyDesk */;
			targetProxy = {IDS["framework_dep"]} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		{IDS["project_debug"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_OPTIMIZATION_LEVEL = 0;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{IDS["project_release"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{IDS["framework_debug"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				BUILD_LIBRARY_FOR_DISTRIBUTION = NO;
				CURRENT_PROJECT_VERSION = 1;
				DEFINES_MODULE = YES;
				DYLIB_COMPATIBILITY_VERSION = 1;
				DYLIB_CURRENT_VERSION = 1;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.wealthmanagement.WealthPolicyDesk;
				PRODUCT_MODULE_NAME = WealthPolicyDesk;
				PRODUCT_NAME = "$(TARGET_NAME:c99extidentifier)";
				SKIP_INSTALL = YES;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_INSTALL_OBJC_HEADER = NO;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "2";
				VERSIONING_SYSTEM = "apple-generic";
				VERSION_INFO_PREFIX = "";
			}};
			name = Debug;
		}};
		{IDS["framework_release"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				BUILD_LIBRARY_FOR_DISTRIBUTION = NO;
				CURRENT_PROJECT_VERSION = 1;
				DEFINES_MODULE = YES;
				DYLIB_COMPATIBILITY_VERSION = 1;
				DYLIB_CURRENT_VERSION = 1;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.wealthmanagement.WealthPolicyDesk;
				PRODUCT_MODULE_NAME = WealthPolicyDesk;
				PRODUCT_NAME = "$(TARGET_NAME:c99extidentifier)";
				SKIP_INSTALL = YES;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_INSTALL_OBJC_HEADER = NO;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "2";
				VERSIONING_SYSTEM = "apple-generic";
				VERSION_INFO_PREFIX = "";
			}};
			name = Release;
		}};
		{IDS["app_debug"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = Example/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "Wealth Policy";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.wealthmanagement.WealthPolicyDeskExample;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "2";
			}};
			name = Debug;
		}};
		{IDS["app_release"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = Example/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "Wealth Policy";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.wealthmanagement.WealthPolicyDeskExample;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{IDS["project_config_list"]} /* Build configuration list for PBXProject "WealthPolicyDesk" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDS["project_debug"]} /* Debug */,
				{IDS["project_release"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{IDS["framework_config_list"]} /* Build configuration list for PBXNativeTarget "WealthPolicyDesk" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDS["framework_debug"]} /* Debug */,
				{IDS["framework_release"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{IDS["app_config_list"]} /* Build configuration list for PBXNativeTarget "WealthPolicyDeskExample" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDS["app_debug"]} /* Debug */,
				{IDS["app_release"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {IDS["project"]} /* Project object */;
}}
'''

(PROJ / "project.pbxproj").write_text(pbxproj)
print(f"Wrote {PROJ / 'project.pbxproj'} with {len(framework_files)} framework files")
