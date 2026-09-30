//
//  AppVersion.swift
//  Nativerate
//
//  Created by Vincent Neo on 2/5/22.
//

import Foundation

let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as! String
let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String
/// The git commit the build was made from (LS_GIT_COMMIT, set by research/typecheck/make_xcode_dev_app.sh);
/// empty for other builds.
let currentCommit = (Bundle.main.infoDictionary?["LSGitCommit"] as? String) ?? ""
/// One line for logs: app, version, build, commit, bundle id.
var appSummary: String {
    "Nativerate \(currentVersion) (build \(currentBuild)\(currentCommit.isEmpty ? "" : ", commit \(currentCommit)")), \(Bundle.main.bundleIdentifier ?? "?")"
}
