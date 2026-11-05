import AppKit

@main struct TranslateGapMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--install-key-stdin") {
            do {
                guard let key = readLine() else { throw AppFailure.message("没有收到 Key。") }
                try KeyStore.save(key)
                guard KeyStore.read() == key.trimmingCharacters(in: .whitespacesAndNewlines) else { throw AppFailure.message("钥匙串保存后读取验证失败。") }
                print("KEYCHAIN_SAVED_AND_VERIFIED")
            }
            catch { fputs("KEYCHAIN_SAVE_FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.contains("--self-test") { Task { @MainActor in await runSelfTests(); exit(0) }; CFRunLoopRun(); return }
        if let index = args.firstIndex(of: "--glass-test"), args.count > index + 1 { runGlassTests(destination: args[index + 1]); return }
        if let index = args.firstIndex(of: "--render-previews"), args.count > index + 1 { renderPreviews(destination: args[index + 1]); return }
        if let index = args.firstIndex(of: "--live-test"), args.count > index + 1 { let key = args.contains("--key-stdin") ? readLine() : nil; Task { @MainActor in await runLiveTests(destination: args[index + 1], key: key); exit(0) }; CFRunLoopRun(); return }
        if let index = args.firstIndex(of: "--exam-live-test"), args.count > index + 1 { let key = args.contains("--key-stdin") ? readLine() : nil; Task { @MainActor in await runExamLiveTest(destination: args[index + 1], key: key); exit(0) }; CFRunLoopRun(); return }
        if let index = args.firstIndex(of: "--research-live-test"), args.count > index + 1 { let key = args.contains("--key-stdin") ? readLine() : nil; Task { @MainActor in await runResearchLiveTest(destination: args[index + 1], key: key, track: args.contains("--ielts") ? .ielts : .cet6); exit(0) }; CFRunLoopRun(); return }
        if let index = args.firstIndex(of: "--passive-test"), args.count > index + 1 {
            let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            let app = NSApplication.shared
            let delegate = AppDelegate(store: TutorStore(folder: folder, api: FakeTutor(), keyAvailable: true))
            delegate.startHidden = true; app.delegate = delegate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
                delegate.showPassive()
                let after = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard before == after, !delegate.panel.isKeyWindow, !app.isActive else { fputs("PASSIVE_TEST_FAILED: focus changed\n", stderr); exit(1) }
                print("PASSIVE_TEST_OK: foreground unchanged, panel visible without key focus, frame \(NSStringFromRect(delegate.panel.frame))")
                app.terminate(nil)
            }
            app.run(); return
        }
        var folder: URL?
        if let index = args.firstIndex(of: "--test-storage"), args.count > index + 1 { folder = URL(fileURLWithPath: args[index + 1], isDirectory: true) }
        let app = NSApplication.shared
        let delegate = AppDelegate(store: TutorStore(folder: folder))
        delegate.startHidden = args.contains("--background")
        app.delegate = delegate; app.run()
    }
}
