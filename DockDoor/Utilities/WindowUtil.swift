//
//  WindowManager.swift
//  DockDoor
//
//  Created by Ethan Bills on 6/3/24.
//

import Cocoa
import ApplicationServices
import ScreenCaptureKit

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let window: SCWindow
    let appName: String
    let bundleID: String
    let windowName: String?
    var image: CGImage?
    var axElement: AXUIElement
    var closeButton: AXUIElement?
}

// Cache item structure
struct CachedImage {
    let image: CGImage
    let timestamp: Date
}

struct CachedAppIcon {
    let icon: NSImage
    let timestamp: Date
}

struct WindowUtil {
    
    private static var imageCache: [CGWindowID: CachedImage] = [:]
    private static var iconCache: [String: CachedAppIcon] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.dockdoor.cacheQueue", attributes: .concurrent)

    private static var cacheExpirySeconds: Double = 600 // 10 mins
    
    static func clearExpiredCache() {
        let now = Date()
        cacheQueue.async(flags: .barrier) {
            imageCache = imageCache.filter { now.timeIntervalSince($0.value.timestamp) <= cacheExpirySeconds / 10 }
            iconCache = iconCache.filter { now.timeIntervalSince($0.value.timestamp) <= cacheExpirySeconds }
        }
    }
    
    // MARK: - Helper Functions
    
    static func captureWindowImage(windowInfo: WindowInfo) async throws -> CGImage {
        clearExpiredCache()
        
        return try cacheQueue.sync(flags: .barrier) {
            if let cachedImage = imageCache[windowInfo.id],
               Date().timeIntervalSince(cachedImage.timestamp) <= cacheExpirySeconds {
                return cachedImage.image
            }
            
            guard CGPreflightScreenCaptureAccess() else {
                print("Debug: Screen recording permission not granted")
                MessageUtil.showMessage(title: "Permission error",
                                        message: "You need to give DockDoor access to Screen Recording in Security & Privacy for it to function.",
                                        completion: { _ in SystemPreferencesHelper.openScreenRecordingPreferences() })
                throw NSError(domain: "com.dockdoor.permission", code: 2, userInfo: [NSLocalizedDescriptionKey: "Screen recording permission not granted"])
            }
            
            let id = windowInfo.id
            let frame = windowInfo.window.frame
            
            guard let image = CGWindowListCreateImage(frame, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
                throw NSError(domain: "com.dockdoor.error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to capture window image"])
            }
            
            let cachedImage = CachedImage(image: image, timestamp: Date())
            imageCache[windowInfo.id] = cachedImage
            
            return image
        }
    }
    
    static func createAXUIElement(for pid: pid_t) -> AXUIElement {
        return AXUIElementCreateApplication(pid)
    }
    
    static func getAXWindows(for appRef: AXUIElement) -> [AXUIElement]? {
        var windowList: AnyObject?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowList)
        
        if result != .success {
            print("Error getting windows: \(result.rawValue)")
            return nil
        }
        
        return windowList as? [AXUIElement]
    }
    
    static func findWindow(byName windowName: String, in windows: [AXUIElement]) -> AXUIElement? {
        for windowRef in windows {
            var windowTitleValue: AnyObject?
            AXUIElementCopyAttributeValue(windowRef, kAXTitleAttribute as CFString, &windowTitleValue)
            if let windowTitle = windowTitleValue as? String, windowTitle == windowName {
                return windowRef
            }
        }
        return nil
    }
    
    static func getCloseButton(for windowRef: AXUIElement) -> AXUIElement? {
        var closeButton: AnyObject?
        let result = AXUIElementCopyAttributeValue(windowRef, kAXCloseButtonAttribute as CFString, &closeButton)
        if result == .success {
            let closeButtonUIElement = closeButton as! AXUIElement
            return closeButtonUIElement
        }
        return nil
    }
    
    // MARK: - Window Manipulation Functions
    
    static func bringWindowToFront(windowInfo: WindowInfo) {
        let raiseResult = AXUIElementPerformAction(windowInfo.axElement, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(windowInfo.axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let frontmostResult = AXUIElementSetAttributeValue(windowInfo.axElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let activateResult = NSRunningApplication(processIdentifier: windowInfo.window.owningApplication?.processID ?? 0)?.activate()
        
        if raiseResult == .success && focusResult == .success && frontmostResult == .success && activateResult == true {
            print("Debug: Successfully raised, focused, and activated window")
        } else {
            print("Error bringing window to front. Raise result: \(raiseResult.rawValue), Focus result: \(focusResult.rawValue), Frontmost result: \(frontmostResult), Activate result: \(String(describing: activateResult))")
            AXUIElementSetAttributeValue(windowInfo.axElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: windowInfo.window.owningApplication?.processID ?? 0)?.activate(options: [.activateAllWindows])
        }
    }
    
    static func closeWindow(closeButton: AXUIElement) {
        let closeResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        if closeResult == .success {
            print("Debug: Successfully closed window")
        } else {
            print("Error closing window: \(closeResult.rawValue)")
        }
    }
    
    static func resetCache() {
        imageCache.removeAll()
        iconCache.removeAll()
    }
    
    // Utility function to list active windows for a specific application
    static func activeWindows(for applicationName: String) async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let group = LimitedTaskGroup<WindowInfo?>(maxConcurrentTasks: 4) // Adjust this number as needed
        
        for window in content.windows {
            if let app = window.owningApplication,
               applicationName.isEmpty || (app.applicationName.contains(applicationName) && !applicationName.isEmpty) {
                await group.addTask {
                    try await fetchWindowInfo(window: window, applicationName: applicationName)
                }
            }
        }
        
        let results = try await group.waitForAll()
        return results.compactMap { $0 }.filter { windowInfo in
            // Filter out windows that have no appName or bundleID, which are likely system windows like the location services icon
            let isSystemWindow = windowInfo.appName.isEmpty || windowInfo.bundleID.isEmpty
                        
            return !isSystemWindow
        }
    }

    private static func fetchWindowInfo(window: SCWindow, applicationName: String) async throws -> WindowInfo? {
        // Check if the window is in the default user space layer and is not fully transparent
        let windowID = window.windowID
        guard let windowInfoDict = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: AnyObject]],
              let windowLayer = windowInfoDict.first?[kCGWindowLayer as String] as? Int,
              windowLayer == 0,
              let windowAlpha = windowInfoDict.first?[kCGWindowAlpha as String] as? Double,
              windowAlpha > 0,
              let owningApplication = window.owningApplication else {
            return nil
        }
        
        let pid = owningApplication.processID
        let appRef = createAXUIElement(for: pid)
        guard let windows = getAXWindows(for: appRef),
              let title = window.title,
              let windowRef = findWindow(byName: title, in: windows) else {
            return nil
        }
        
        let closeButton = getCloseButton(for: windowRef)
        
        var windowInfo = WindowInfo(
            id: windowID,
            window: window,
            appName: owningApplication.applicationName,
            bundleID: owningApplication.bundleIdentifier,
            windowName: window.title,
            image: nil,
            axElement: windowRef,
            closeButton: closeButton
        )
        
        do {
            windowInfo.image = try await captureWindowImage(windowInfo: windowInfo)
            return windowInfo
        } catch {
            print("Error capturing window image: \(error)")
            return nil
        }
    }
}

actor LimitedTaskGroup<T> {
    private var tasks: [Task<T, Error>] = []
    private let maxConcurrentTasks: Int
    private var runningTasks = 0
    
    init(maxConcurrentTasks: Int) {
        self.maxConcurrentTasks = maxConcurrentTasks
    }
    
    func addTask(_ operation: @escaping () async throws -> T) {
        let task = Task {
            while self.runningTasks >= self.maxConcurrentTasks {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            self.runningTasks += 1
            defer { self.runningTasks -= 1 }
            return try await operation()
        }
        tasks.append(task)
    }
    
    func waitForAll() async throws -> [T] {
        var results: [T] = []
        for task in tasks {
            do {
                let result = try await task.value
                results.append(result)
            } catch {
                print("Task failed with error: \(error)")
            }
        }
        tasks.removeAll()
        return results
    }
}
