//
//  SwapBarApp.swift
//  SwapBar
//
//  Created by Ethan Johnson on 8/12/26.
//

import SwiftUI

@main
struct SwapBarApp: App {
    // The menu bar icon and dropdown are owned entirely by AppDelegate via a native
    // NSStatusItem/NSPopover — see AppDelegate.swift for why. This Scene is a required but
    // otherwise-unused placeholder; LSUIElement (Info.plist) already suppresses the Dock
    // icon and app menu bar, and `Settings` never shows anything unless invoked explicitly.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
