import AppKit

/// The native app menu owns Settings; SwiftUI only hosts the window's content.
@MainActor
enum VoiceBarMainMenu {
    static func install(appDelegate: AppDelegate) {
        let application = NSApplication.shared
        application.mainMenu = make(appDelegate: appDelegate)
        application.windowsMenu = application.mainMenu?.item(withTitle: "Window")?.submenu
    }

    static func make(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu(title: "VoiceBar")
        appItem.submenu = app
        app.addItem(withTitle: "About VoiceBar",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "").target = NSApplication.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettingsWindow(_:)),
                    keyEquivalent: ",").target = appDelegate
        app.addItem(.separator())
        // Authorize the same termination policy and cleanup as the status-item Quit.
        app.addItem(withTitle: "Quit VoiceBar", action: #selector(AppDelegate.quitFromMenuBar),
                    keyEquivalent: "q").target = appDelegate

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            // A nil target routes through the focused field editor's responder chain.
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        windowItem.submenu = window
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        return main
    }
}
